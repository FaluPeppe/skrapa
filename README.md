# skrapfunktioner

Samlade funktioner för webbskrapning via `chromote`/`selenider`, plus ett
interaktivt inspelningsgadget som genererar R-kod utifrån dessa funktioner.

## Struktur

- `R/skrapning.R` - kärnfunktionerna (tidigare `func_webbskrapning.R`):
  starta/stäng session, klicka, fylla i formulär, vänta, ladda ner filer
  med mera. Beroenden i `Imports` (installeras alltid).
- `R/inspelning.R` - `kor_inspelningsgadget()` och stödfunktioner: spelar in
  klick/formulärval i en synlig webbläsarsession och genererar ett R-skript
  byggt på funktionerna i `skrapning.R`. Beroenden (`shiny`, `miniUI`,
  `dplyr`, `tibble`, `purrr`) ligger i `Suggests`, eftersom vanliga
  skrapskript som bara använder `skrapning.R` inte ska behöva dra in dem.

## Installation

```r
# lokalt, från en klon av repot:
pak::pak(".")

# eller direkt från GitHub när det är pushat:
pak::pak("Region-Dalarna/skrapfunktioner")
```

## Kommande steg

- [ ] Döp om paketet om `skrapfunktioner` inte känns rätt (sök/ersätt i
      `DESCRIPTION`).
- [ ] Kör `roxygen2::roxygenise()` (kräver `roxygen2`-paketet installerat)
      för att bygga om `NAMESPACE` och `man/`-hjälpsidorna automatiskt
      utifrån `@export`-taggarna och roxygen-kommentarerna i `R/*.R` -
      `NAMESPACE` är just nu handskriven som en startpunkt.
- [ ] Kör `devtools::check()` för att fånga eventuella kvarvarande problem
      (saknade `@param`/titlar på funktioner som `hitta_webblasare()` och
      `testa_skrapmiljo()`, som saknade fullständig roxygen-dokumentation
      redan i originalfilen).
- [ ] Fundera på om `generera_rad()` ska vara exporterad eller intern
      (`@keywords internal`) - den är just nu satt som publik för enkelhets
      skull, men används normalt bara internt av `generera_skript()`.
- [ ] Lägg till `testthat`-tester, särskilt för `generera_rad()`s
      prioriteringslogik (id → text → klass+text → `kor_js()`-fallback).
