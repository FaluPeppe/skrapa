# skrapa

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
pak::pak("Region-Dalarna/skrapa")
```

## Kommande steg


