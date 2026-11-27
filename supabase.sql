-- Het Wensbos · database voor de verlanglijstjes
-- Plak dit in Supabase → SQL Editor → New query, en klik Run.
-- Je kunt dit bestand gerust opnieuw draaien: het past alleen aan wat nodig is en maakt niets dubbel.
--
-- Inloggen: iedereen kiest de eerste keer zelf een code. Daarna is die code nodig om je eigen
-- lijstje aan te passen. Bekijken kan iedereen. Code vergeten? Zie onderaan (stap 5).

-- 1. Tabellen -------------------------------------------------------------
create extension if not exists pgcrypto with schema extensions;

create table if not exists public.leden (
  id   text primary key,
  naam text not null
);
alter table public.leden add column if not exists code_hash text;

create table if not exists public.cadeaus (
  id                uuid primary key default gen_random_uuid(),
  eigenaar          text not null references public.leden(id) on delete cascade,
  titel             text not null check (char_length(titel) between 1 and 120),
  prijs             text not null default '' check (char_length(prijs) <= 30),
  link              text not null default '' check (link = '' or link ~* '^https?://'),
  notitie           text not null default '' check (char_length(notitie) <= 1000),
  fav               boolean not null default false,
  gemaakt_op        timestamptz not null default now()
);

-- Update 1.2: langere notitie (met enters) en tot 3 links met een eigen naam ("via Bol", "via Amazon"…).
-- links = [{"url": "https://…", "label": "via Bol"}, …]. De oude kolom link houdt de eerste link.
alter table public.cadeaus add column if not exists links jsonb not null default '[]'::jsonb;
alter table public.cadeaus drop constraint if exists cadeaus_notitie_check;
alter table public.cadeaus add constraint cadeaus_notitie_check check (char_length(notitie) <= 1000);
update public.cadeaus set links = jsonb_build_array(jsonb_build_object('url', link, 'label', ''))
 where link <> '' and links = '[]'::jsonb;

-- Wie wat koopt. Anderen zien alleen DAT het geregeld is, nooit door wie; de eigenaar ziet niets.
create table if not exists public.afgevinkt (
  cadeau uuid not null references public.cadeaus(id) on delete cascade,
  lid    text not null references public.leden(id) on delete cascade,
  primary key (cadeau, lid)
);

-- Tabellen dicht: niemand leest of schrijft er direct in, alleen via de functies hieronder.
alter table public.leden     enable row level security;
alter table public.cadeaus   enable row level security;
alter table public.afgevinkt enable row level security;
revoke all on public.leden, public.cadeaus, public.afgevinkt from anon, authenticated;

-- 2. Functies -------------------------------------------------------------
-- Oude versies zonder code opruimen.
drop function if exists public.cadeau_toevoegen(text, text, text, text, text, boolean);
drop function if exists public.cadeau_verwijderen(text, uuid);
drop function if exists public.reserveren(text, uuid, boolean);
-- Versies zonder p_links (vóór update 1.2) opruimen; de nieuwe hieronder snappen oude aanroepen ook nog.
drop function if exists public.cadeau_toevoegen(text, text, text, text, text, text, boolean);
drop function if exists public.cadeau_bijwerken(text, text, uuid, text, text, text, text, boolean);

-- Links controleren en opschonen: max 3, alleen http(s), naam max 40 tekens, lege regels weg.
-- Geen p_links meegegeven (oude versie van de site)? Dan wordt p_link de enige link.
create or replace function public.schone_links(p_links jsonb, p_link text)
returns jsonb language plpgsql immutable set search_path = public as $$
declare uit jsonb := '[]'::jsonb; x jsonb; u text; l text;
begin
  if p_links is null or jsonb_typeof(p_links) <> 'array' then
    p_links := case when coalesce(trim(p_link), '') = '' then '[]'::jsonb
                    else jsonb_build_array(jsonb_build_object('url', trim(p_link), 'label', '')) end;
  end if;
  for x in select * from jsonb_array_elements(p_links) loop
    u := trim(coalesce(x->>'url', ''));
    l := trim(coalesce(x->>'label', ''));
    continue when u = '';
    if u !~* '^https?://' then raise exception 'Een link moet met https:// beginnen'; end if;
    if char_length(u) > 500 then raise exception 'Een link is te lang'; end if;
    if char_length(l) > 40 then raise exception 'De naam van een link mag maximaal 40 tekens zijn'; end if;
    uit := uit || jsonb_build_array(jsonb_build_object('url', u, 'label', l));
  end loop;
  if jsonb_array_length(uit) > 3 then raise exception 'Maximaal 3 links per cadeau'; end if;
  return uit;
end $$;

-- Alle lijstjes (bekijken mag iedereen). Wie ingelogd is (naam + juiste code) ziet bij ANDERMANS
-- cadeaus of het al geregeld is (gereserveerd) en of hij/zij dat zelf is (door_mij). Nooit wie het is,
-- en op je eigen lijstje zie je niets.
drop function if exists public.lijsten(text);
drop function if exists public.lijsten(text, text);
create or replace function public.lijsten(p_kijker text default null, p_code text default null)
returns table (id uuid, eigenaar text, titel text, prijs text, link text, links jsonb, notitie text,
               fav boolean, gereserveerd boolean, door_mij boolean)
language plpgsql stable security definer set search_path = public, extensions as $$
declare v text := null;
begin
  if p_kijker is not null and check_code(p_kijker, p_code) then v := p_kijker; end if;
  return query
    select c.id, c.eigenaar, c.titel, c.prijs, c.link, c.links, c.notitie, c.fav,
           (v is not null and v <> c.eigenaar and exists (select 1 from afgevinkt a where a.cadeau = c.id)),
           (v is not null and v <> c.eigenaar and exists (select 1 from afgevinkt a where a.cadeau = c.id and a.lid = v))
    from cadeaus c
    order by c.fav desc, c.gemaakt_op;
end $$;

-- 'nieuw' = heeft nog geen code, 'code' = heeft al een code.
create or replace function public.lid_status(p_lid text)
returns text language sql stable security definer set search_path = public as $$
  select case when code_hash is null then 'nieuw' else 'code' end from leden where id = p_lid;
$$;

create or replace function public.check_code(p_lid text, p_code text)
returns boolean language sql stable security definer set search_path = public, extensions as $$
  select exists (select 1 from leden
                 where id = p_lid and code_hash is not null and code_hash = crypt(coalesce(p_code, ''), code_hash));
$$;

-- Eerste keer: je eigen code kiezen. Lukt alleen als er nog geen code is.
create or replace function public.code_instellen(p_lid text, p_code text)
returns boolean language plpgsql security definer set search_path = public, extensions as $$
begin
  if char_length(coalesce(p_code, '')) < 4 then raise exception 'Kies een code van minstens 4 tekens'; end if;
  update leden set code_hash = crypt(p_code, gen_salt('bf')) where id = p_lid and code_hash is null;
  return found;
end $$;

create or replace function public.cadeau_toevoegen(p_lid text, p_code text, p_titel text, p_prijs text,
                                                   p_link text, p_notitie text, p_fav boolean,
                                                   p_links jsonb default null)
returns uuid language plpgsql security definer set search_path = public, extensions as $$
declare nieuw uuid; ls jsonb;
begin
  if not check_code(p_lid, p_code) then raise exception 'Code klopt niet'; end if;
  ls := schone_links(p_links, p_link);
  insert into cadeaus (eigenaar, titel, prijs, link, links, notitie, fav)
  values (p_lid, trim(p_titel), coalesce(trim(p_prijs), ''), coalesce(ls->0->>'url', ''), ls,
          coalesce(trim(p_notitie), ''), coalesce(p_fav, false))
  returning cadeaus.id into nieuw;
  return nieuw;
end $$;

create or replace function public.cadeau_bijwerken(p_lid text, p_code text, p_id uuid, p_titel text, p_prijs text,
                                                   p_link text, p_notitie text, p_fav boolean,
                                                   p_links jsonb default null)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare ls jsonb;
begin
  if not check_code(p_lid, p_code) then raise exception 'Code klopt niet'; end if;
  ls := schone_links(p_links, p_link);
  update cadeaus set titel = trim(p_titel), prijs = coalesce(trim(p_prijs), ''), link = coalesce(ls->0->>'url', ''), links = ls,
                     notitie = coalesce(trim(p_notitie), ''), fav = coalesce(p_fav, false)
   where id = p_id and eigenaar = p_lid;
  if not found then raise exception 'Cadeau niet gevonden'; end if;
end $$;

create or replace function public.cadeau_verwijderen(p_lid text, p_code text, p_id uuid)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
  if not check_code(p_lid, p_code) then raise exception 'Code klopt niet'; end if;
  delete from cadeaus where id = p_id and eigenaar = p_lid;
end $$;

create or replace function public.reserveren(p_lid text, p_code text, p_id uuid, p_aan boolean)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
  if not check_code(p_lid, p_code) then raise exception 'Code klopt niet'; end if;
  if p_aan then
    if exists (select 1 from afgevinkt where cadeau = p_id and lid <> p_lid) then
      raise exception 'Iemand anders regelt dit al';
    end if;
    insert into afgevinkt (cadeau, lid)
    select c.id, p_lid from cadeaus c where c.id = p_id and c.eigenaar <> p_lid
    on conflict do nothing;
  else
    delete from afgevinkt where cadeau = p_id and lid = p_lid;
  end if;
end $$;

revoke all on function public.lijsten(text, text), public.lid_status(text), public.check_code(text, text),
  public.code_instellen(text, text), public.cadeau_toevoegen(text, text, text, text, text, text, boolean, jsonb),
  public.cadeau_bijwerken(text, text, uuid, text, text, text, text, boolean, jsonb),
  public.cadeau_verwijderen(text, text, uuid), public.reserveren(text, text, uuid, boolean),
  public.schone_links(jsonb, text) from public;
grant execute on function public.lijsten(text, text), public.lid_status(text), public.check_code(text, text),
  public.code_instellen(text, text), public.cadeau_toevoegen(text, text, text, text, text, text, boolean, jsonb),
  public.cadeau_bijwerken(text, text, uuid, text, text, text, text, boolean, jsonb),
  public.cadeau_verwijderen(text, text, uuid), public.reserveren(text, text, uuid, boolean) to anon, authenticated;

-- 3. Familieleden ---------------------------------------------------------
insert into public.leden (id, naam) values
  ('benno', 'Benno'), ('tijme', 'Tijme'), ('aletha', 'Aletha'), ('sieb', 'Sieb'),
  -- Tjiske & Joop: één gezamenlijke inlog, geen eigen lijstje, wel cadeaus claimen
  ('opa', 'Tjiske & Joop')
on conflict (id) do nothing;

-- 4. Startcadeaus (alleen als de lijst nog helemaal leeg is) ---------------
insert into public.cadeaus (eigenaar, titel, prijs, link, notitie, fav)
select * from (values
  ('tijme', 'MIZU M8 waterfles groen (750 ml)', '€24', 'https://mizulife.eu/products/m8',
   'Kleur Leaf, Spring Green of Safari Green — of een customized versie', true),
  ('tijme', 'Carhartt WIP Harlem pet, bordeaux/wit', '€38,95',
   'https://www.zalando.nl/carhartt-wip-harlem-unisex-pet-bordeauxwhite-c1454b05w-g12.html', 'One size', false)
) v(eigenaar, titel, prijs, link, notitie, fav)
where not exists (select 1 from public.cadeaus);

-- 5. Code vergeten? -------------------------------------------------------
-- Draai dan los (met de juiste naam):   update public.leden set code_hash = null where id = 'benno';
-- Daarna kan die persoon via zijn of haar link een nieuwe code kiezen.
