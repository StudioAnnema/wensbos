# Het Wensbos 🌲

De verlanglijstjes van familie Annema & Bos, als 8-bit spelletje.
Live: https://studioannema.github.io/wensbos/

## Een cadeau op je verlanglijstje zetten

### Met de database (zodra die aan staat)

1. Open je eigen link (bijv. `https://studioannema.github.io/wensbos/#/ik/tijme`).
   De eerste keer verzin je een eigen code; daarna vul je die in als je inlogt.
2. Je komt meteen op je eigen verlanglijstje: vul onderaan **CADEAU TOEVOEGEN** in.

Persoonlijke links: `#/ik/benno`, `#/ik/tijme`, `#/ik/aletha`, `#/ik/sieb`.
Code vergeten? In Supabase → SQL Editor: `update public.leden set code_hash = null where id = 'benno';`

### Zonder database (via GitHub)

1. Open je eigen bestand in de map [`wensen/`](wensen/) (bijv. `wensen/tijme.md`).
2. Klik rechtsboven op het potloodje ✎ (bewerken) en zet er per cadeau één regel bij:

   ```
   - Titel | prijs | link | notitie
   ```

   Alleen de titel is verplicht. Begin met `★` als je iets héél graag wilt.
3. Klik op **Commit changes**. Binnen een minuutje staat het online.

## De database aanzetten (eenmalig)

1. Maak een gratis account en project aan op https://supabase.com.
2. Ga naar **SQL Editor → New query**, plak de inhoud van [`supabase.sql`](supabase.sql) en klik **Run**.
3. Ga naar **Project Settings → API** en kopieer de **Project URL** en de **anon public key**.
4. Zet die twee in [`config.js`](config.js) en sla op. Klaar: de site gebruikt vanaf nu de database.

De publishable/anon key mag openbaar staan. De tabellen zelf zijn dicht: alles loopt via de functies uit `supabase.sql`.

## Delen

Directe link naar iemands lijstje: `https://studioannema.github.io/wensbos/#/tijme`
(of `#/benno`, `#/aletha`, `#/sieb`). Een vaste wereld: `?wereld=bos`, `?wereld=fuji` of `?wereld=strand`.
