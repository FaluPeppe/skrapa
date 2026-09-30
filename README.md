# skrapa

Ett R-paket för att styra en webbläsare automatiskt: öppna sidor, klicka på
knappar, fylla i formulär, välja i listor och ladda ner filer - utan att
sitta och klicka manuellt varje gång. Byggt för sidor som kräver inloggning
eller är för komplexa för enkel `httr`/`rvest`-skrapning (t.ex.
JavaScript-tunga sidor, Qlik-rapporter, ASP.NET-formulär).

Du behöver **inte kunna JavaScript eller webbutveckling** för att använda
paketet - se avsnittet "Kom igång utan att skriva kod själv" nedan.

## Installation

```r
# Installera pak om du inte redan har det:
install.packages("pak")

# Installera skrapa direkt från GitHub:
pak::pak("FaluPeppe/skrapa")
```

Du behöver också Microsoft Edge eller Google Chrome installerat (de flesta
jobbdatorer har redan Edge). Kör sedan alltid detta en gång efter
installation, för att kontrollera att allt fungerar på just din dator:

```r
library(skrapa)
testa_skrapmiljo()
```

Den går igenom internetanslutning, installerade paket, webbläsare och
brandvägg i tur och ordning och talar om exakt var det brister om något
inte fungerar, istället för ett kryptiskt felmeddelande längre fram.

## Kom igång utan att skriva kod själv

Det snabbaste sättet att komma igång är att **spela in** vad du gör i
webbläsaren, och låta paketet skriva R-koden åt dig:

```r
library(skrapa)
kor_inspelningsgadget(url = "https://exempel.se/statistik")
```

Detta öppnar ett synligt webbläsarfönster tillsammans med en liten
kontrollpanel i RStudio. Klicka och fyll i formulär i webbläsarfönstret
precis som du annars skulle göra manuellt - varje klick och val loggas i
kontrollpanelens flik "Logg". Fliken "Genererad kod" visar samtidigt,
live, det R-skript som motsvarar det du gjort hittills.

När du är klar, tryck **Done**. Skriptet skrivs då ut i konsolen och
kopieras automatiskt till urklipp - klistra in det i ett nytt R-skript.
Skriptet är ett **utkast**: leta efter rader som börjar med `# OBS:` -
de markerar ställen där inspelningen var osäker och du bör dubbelkolla
eller komplettera för hand. Annars går det oftast att köra rakt av.
Inspelningen identifierar varje klick i turordning id → `aria-label`
(vanligt på ikonknappar utan synlig text) → unik text → unik klass+text
→ DOM-position som sista utväg - ju tidigare i den listan, desto
stabilare blir raden mellan olika körningar.

Detta är det rekommenderade sättet att börja - även om du tänker skriva
om eller finslipa skriptet för hand efteråt, sparar det mycket tid att
utgå från ett inspelat utkast istället för att börja från noll.

## Att skriva ett skript för hand

Ett skrapskript har alltid samma grundform: starta en session, gör saker
på sidan, stäng sessionen.

```r
library(skrapa)

skrap <- starta_skrapsession()          # startar webbläsaren i bakgrunden
on.exit(stang_skrapsession(skrap))      # sett så den alltid städas bort

selenider::open_url(skrap$session, "https://exempel.se/statistik")

# Klicka på en knapp/länk via dess synliga text:
klicka_via_text(skrap, "Visa statistik")

# ... eller via ett id (snabbare, om du vet id:t):
klicka_via_id(skrap, "#visa-knapp")

# Välj ett alternativ i en dropdown-lista:
valj_i_lista(skrap, "select#ar", "2024")

# Skriv text i ett textfält:
textruta_inmatning(skrap, "#sokruta", "Dalarna")

stang_skrapsession(skrap)
```

Vill du se **vilka knappar/listor/fält en sida faktiskt har** (deras id,
text och värden) innan du skriver klicken, kör:

```r
skrap <- starta_skrapsession(headless = FALSE)   # FALSE = se webbläsaren
selenider::open_url(skrap$session, "https://exempel.se/statistik")
visa_kontroller(skrap)
```

Den skriver ut en lättläst lista över alla dropdown-listor, klickbara
element och inmatningsfält på sidan, inklusive färdiga exempelanrop att
kopiera in i ditt skript.

### Ladda ner filer

```r
fil <- hamta_nedladdning(
  skrap,
  trigger = function() klicka_via_text(skrap, "Ladda ner Excel"),
  nedladdningsmapp = "C:/temp/nedladdningar"
)
# fil innehåller nu sökvägen till den nedladdade filen
```

### Flera filer på en gång

Om en sida listar flera nedladdningsbara filer (t.ex. en rapport per år):

```r
filer <- hamta_flera_nedladdningar(
  skrap,
  matchning = "Kvartalsrapport",
  nedladdningsmapp = "C:/temp/rapporter"
)
```

## Vanliga problem

**Ett klick verkar ske "för tidigt", innan sidan hunnit ladda klart**
(vanligt på sidor byggda med Qlik, React, Vue eller liknande, där
innehållet uppdateras i bakgrunden efter att sidan redan "ser klar ut").
Klick-funktionerna (`klicka_via_id()`, `klicka_via_text()` m.fl.) väntar
redan automatiskt in detta - du behöver oftast inte göra något extra. Om
en sida ändå har problem, prova att höja väntetiden:

```r
klicka_via_id(skrap, "#knapp", dom_stabil_tid = 1)   # vänta 1 sekund i stället för 0.3
```

Har sidan istället innehåll som *aldrig* slutar uppdateras (t.ex. en
klocka eller en auto-uppdaterande widget), stäng av väntan helt för just
det klicket:

```r
klicka_via_id(skrap, "#knapp", dom_stabil_tid = NULL)
```

**"Hittade inget element..." direkt efter open_url() eller ett tidigare
klick** - det du klickar på finns ofta inte i DOM:en ännu i just det
ögonblicket (t.ex. första klicket på en sida byggd med React/Vue/MUI, som
behöver en liten stund att rendera klart efter att sidan öppnats).
Klick-funktionerna väntar redan i upp till 10 sekunder på att elementet
dyker upp innan de ger upp - räcker inte det på en särskilt trög sida,
höj det med `timeout_finns`:

```r
klicka_via_id(skrap, "#knapp", timeout_finns = 20)
```

**Edge/Chrome startar inte, eller AppLocker/gruppolicy blockerar**
Kör `testa_skrapmiljo()` - den talar om exakt vilket steg som failar och
vad du (eller din IT-avdelning) behöver göra åt det.

**Jag vet inte vilket id/vilken text jag ska använda**
Kör `visa_kontroller(skrap)` på sidan du vill skrapa (se ovan), eller
spela in ditt agerande med `kor_inspelningsgadget()` istället för att
leta upp selektorer för hand.

## Paketets innehåll, kort

- `R/skrapning.R` - kärnfunktionerna: starta/stäng session, klicka, fylla
  i formulär, vänta in sidladdningar, ladda ner filer.
- `R/inspelning.R` - `kor_inspelningsgadget()` och stödfunktioner för att
  spela in och generera R-kod, se ovan.

Kör `help(package = "skrapa")` för en fullständig lista över alla
funktioner, eller t.ex. `?klicka_via_id` för hjälp om en specifik funktion.
