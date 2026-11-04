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
  notitie           text not null default '' check (char_length(notitie) <= 200),
  fav               boolean not null default false,
  gemaakt_op        timestamptz not null default now()
);

-- Wie wat koopt (wordt nu niet gebruikt op de site, maar blijft geheim als het ooit terugkomt).
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

-- Alle lijstjes (bekijken mag iedereen).
drop function if exists public.lijsten(text);
create or replace function public.lijsten(p_kijker text default null)
returns table (id uuid, eigenaar text, titel text, prijs text, link text, notitie text,
               fav boolean, door_mij boolean)
language sql stable security definer set search_path = public as $$
  select c.id, c.eigenaar, c.titel, c.prijs, c.link, c.notitie, c.fav,
         exists (select 1 from afgevinkt a where a.cadeau = c.id and a.lid = p_kijker and p_kijker <> c.eigenaar)
  from cadeaus c
  order by c.fav desc, c.gemaakt_op;
$$;

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
                                                   p_link text, p_notitie text, p_fav boolean)
returns uuid language plpgsql security definer set search_path = public, extensions as $$
declare nieuw uuid;
begin
  if not check_code(p_lid, p_code) then raise exception 'Code klopt niet'; end if;
  insert into cadeaus (eigenaar, titel, prijs, link, notitie, fav)
  values (p_lid, trim(p_titel), coalesce(trim(p_prijs), ''), coalesce(trim(p_link), ''), coalesce(trim(p_notitie), ''), coalesce(p_fav, false))
  returning cadeaus.id into nieuw;
  return nieuw;
end $$;

create or replace function public.cadeau_bijwerken(p_lid text, p_code text, p_id uuid, p_titel text, p_prijs text,
                                                   p_link text, p_notitie text, p_fav boolean)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
  if not check_code(p_lid, p_code) then raise exception 'Code klopt niet'; end if;
  update cadeaus set titel = trim(p_titel), prijs = coalesce(trim(p_prijs), ''), link = coalesce(trim(p_link), ''),
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
    insert into afgevinkt (cadeau, lid)
    select c.id, p_lid from cadeaus c where c.id = p_id and c.eigenaar <> p_lid
    on conflict do nothing;
  else
    delete from afgevinkt where cadeau = p_id and lid = p_lid;
  end if;
end $$;

revoke all on function public.lijsten(text), public.lid_status(text), public.check_code(text, text),
  public.code_instellen(text, text), public.cadeau_toevoegen(text, text, text, text, text, text, boolean),
  public.cadeau_bijwerken(text, text, uuid, text, text, text, text, boolean),
  public.cadeau_verwijderen(text, text, uuid), public.reserveren(text, text, uuid, boolean) from public;
grant execute on function public.lijsten(text), public.lid_status(text), public.check_code(text, text),
  public.code_instellen(text, text), public.cadeau_toevoegen(text, text, text, text, text, text, boolean),
  public.cadeau_bijwerken(text, text, uuid, text, text, text, text, boolean),
  public.cadeau_verwijderen(text, text, uuid), public.reserveren(text, text, uuid, boolean) to anon, authenticated;

-- 3. Familieleden ---------------------------------------------------------
insert into public.leden (id, naam) values
  ('benno', 'Benno'), ('tijme', 'Tijme'), ('aletha', 'Aletha'), ('sieb', 'Sieb')
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
