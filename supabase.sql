-- Het Wensbos · database voor de verlanglijstjes
-- Plak dit in Supabase → SQL Editor → New query, en klik Run. Meer hoef je niet te doen.
-- Er is geen pincode: op de site kiest iedereen één keer wie hij of zij is, en de browser onthoudt dat.

-- 1. Tabellen -------------------------------------------------------------
create table if not exists public.leden (
  id   text primary key,
  naam text not null
);

create table if not exists public.cadeaus (
  id                uuid primary key default gen_random_uuid(),
  eigenaar          text not null references public.leden(id) on delete cascade,
  titel             text not null check (char_length(titel) between 1 and 120),
  prijs             text not null default '' check (char_length(prijs) <= 30),
  link              text not null default '' check (link = '' or link ~* '^https?://'),
  notitie           text not null default '' check (char_length(notitie) <= 200),
  fav               boolean not null default false,
  gereserveerd_door text references public.leden(id) on delete set null,
  gemaakt_op        timestamptz not null default now()
);

-- Tabellen dicht: niemand leest of schrijft er direct in, alleen via de functies hieronder.
-- Zo kan de site nooit laten zien wie wat koopt aan degene voor wie het cadeau is.
alter table public.leden   enable row level security;
alter table public.cadeaus enable row level security;
revoke all on public.leden, public.cadeaus from anon, authenticated;

-- 2. Functies -------------------------------------------------------------
-- Alle lijstjes. Wat al geregeld is, zie je alleen als je gekozen hebt wie je bent en het niet je eigen lijstje is.
create or replace function public.lijsten(p_kijker text default null)
returns table (id uuid, eigenaar text, titel text, prijs text, link text, notitie text,
               fav boolean, gereserveerd boolean, door_mij boolean)
language sql stable security definer set search_path = public as $$
  select c.id, c.eigenaar, c.titel, c.prijs, c.link, c.notitie, c.fav,
         (p_kijker is not null and p_kijker <> c.eigenaar and c.gereserveerd_door is not null),
         (p_kijker is not null and p_kijker <> c.eigenaar and coalesce(c.gereserveerd_door = p_kijker, false))
  from cadeaus c
  order by c.fav desc, c.gemaakt_op;
$$;

create or replace function public.cadeau_toevoegen(p_lid text, p_titel text, p_prijs text,
                                                   p_link text, p_notitie text, p_fav boolean)
returns uuid language plpgsql security definer set search_path = public as $$
declare nieuw uuid;
begin
  if not exists (select 1 from leden where id = p_lid) then raise exception 'Onbekend familielid'; end if;
  insert into cadeaus (eigenaar, titel, prijs, link, notitie, fav)
  values (p_lid, trim(p_titel), coalesce(trim(p_prijs), ''), coalesce(trim(p_link), ''), coalesce(trim(p_notitie), ''), coalesce(p_fav, false))
  returning cadeaus.id into nieuw;
  return nieuw;
end $$;

create or replace function public.cadeau_verwijderen(p_lid text, p_id uuid)
returns void language sql security definer set search_path = public as $$
  delete from cadeaus where id = p_id and eigenaar = p_lid;
$$;

-- Afvinken (p_aan = true) of je afvinking terugdraaien (p_aan = false). Nooit op je eigen lijstje.
create or replace function public.reserveren(p_lid text, p_id uuid, p_aan boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from leden where id = p_lid) then raise exception 'Onbekend familielid'; end if;
  if p_aan then
    update cadeaus set gereserveerd_door = p_lid
     where id = p_id and eigenaar <> p_lid and gereserveerd_door is null;
    if not found then raise exception 'Iemand anders regelt dit al'; end if;
  else
    update cadeaus set gereserveerd_door = null where id = p_id and gereserveerd_door = p_lid;
  end if;
end $$;

revoke all on function public.lijsten(text), public.cadeau_toevoegen(text, text, text, text, text, boolean),
  public.cadeau_verwijderen(text, uuid), public.reserveren(text, uuid, boolean) from public;
grant execute on function public.lijsten(text), public.cadeau_toevoegen(text, text, text, text, text, boolean),
  public.cadeau_verwijderen(text, uuid), public.reserveren(text, uuid, boolean) to anon, authenticated;

-- 3. Familieleden ---------------------------------------------------------
insert into public.leden (id, naam) values
  ('benno', 'Benno'), ('tijme', 'Tijme'), ('aletha', 'Aletha'), ('sieb', 'Sieb')
on conflict (id) do nothing;

-- 4. Wat er nu al op de lijstjes staat ------------------------------------
insert into public.cadeaus (eigenaar, titel, prijs, link, notitie, fav) values
  ('tijme', 'MIZU M8 waterfles groen (750 ml)', '€24', 'https://mizulife.eu/products/m8',
   'Kleur Leaf, Spring Green of Safari Green — of een customized versie', true),
  ('tijme', 'Carhartt WIP Harlem pet, bordeaux/wit', '€38,95',
   'https://www.zalando.nl/carhartt-wip-harlem-unisex-pet-bordeauxwhite-c1454b05w-g12.html', 'One size', false);
