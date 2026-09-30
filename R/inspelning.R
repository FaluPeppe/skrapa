#' Spela in klick/formulärval i en skrapsession och generera R-kod
#'
#' Bygger vidare på funktionerna i skrapning.R (samma paket). Tanken:
#'   1. injicera_inspelning() lägger en global JS-lyssnare i sidan som
#'      fångar klick och select/input-ändringar, sparat i sessionStorage.
#'   2. lasa_av_inspelning() läser av (och tömmer) loggen från R.
#'   3. generera_skript() översätter de inspelade händelserna till anrop
#'      mot klicka_via_id() / klicka_via_klass_och_text() / klicka_via_text()
#'      / selenider::elem_select() / kor_js()-fallback.
#'   4. kor_inspelningsgadget() är ett litet Shiny-gadget (miniUI) som körs
#'      LOKALT (inte deployat) och visar en enkel kontrollpanel bredvid det
#'      synliga Edge-fönstret: Starta, Stoppa, Visa/kopiera genererad kod.
#'
#' Utvecklarverktyg - shiny/miniUI/dplyr/tibble/purrr ligger i Suggests,
#' inte Imports, eftersom vanliga skrapskript (som bara använder
#' funktionerna i skrapning.R) inte ska behöva dra in dem.
#' @keywords internal
"_PACKAGE"

# dplyr::select() i kor_inspelningsgadget()s renderTable() refererar till
# kolumnnamn (hantelse, tag, id, ...) som bara finns i data-argumentet vid
# körning, inte i paketets namnrymd - utan den här skulle R CMD check tro
# att det är odefinierade globala variabler.
utils::globalVariables(c(
  "hantelse", "tag", "id", "klass", "text", "vald_text", "varde",
  "iframe", "sokvag", "aria_label"
))

# --- 0. Städa policy-styrda extra-flikar ------------------------------------

#' Stäng alla flikar utom den skrapsessionen faktiskt använder
#'
#' Edge öppnar ofta en policy-styrd startsida (t.ex. ett intranät) som en
#' egen flik vid start, utöver den flik chromote/selenider skapar åt sig
#' själv för skrapsessionen - även med en tom, temporär profil, eftersom
#' den typen av policy oftast är maskinbunden snarare än profilbunden.
#' Den här stänger allt utom vår egen flik.
#'
#' @param skrap Ett objekt skapat av starta_skrapsession().
#' @return Inget (osynligt TRUE).
#' @export
stang_extra_flikar <- function(skrap) {
  if (!inherits(skrap, "skrapsession")) {
    stop("Objektet ar inte skapat av starta_skrapsession().")
  }
  egen_id <- skrap$session$driver$Target$getTargetInfo()$targetInfo$targetId
  alla <- skrap$session$driver$Target$getTargets()$targetInfos
  sidor <- Filter(function(t) identical(t$type, "page"), alla)
  
  for (t in sidor) {
    if (!identical(t$targetId, egen_id)) {
      skrap$session$driver$Target$closeTarget(targetId = t$targetId)
    }
  }
  invisible(TRUE)
}

# --- 1. Injicera inspelnings-JS --------------------------------------------

#' Starta inspelning av klick och formulärändringar på aktuell sida
#'
#' Sparar till `sessionStorage` (nyckel `__skrap_inspelning__`) - INTE en
#' vanlig JS-variabel, eftersom en sådan nollställs direkt av en riktig
#' sidnavigering (till skillnad från t.ex. en overlay som bara stängs).
#' `sessionStorage` bevaras av webbläsaren över navigeringar inom samma
#' origin, vilket är avgörande för att inte tappa just den händelse som
#' triggar sidladdningen (annars hinner R:s nästa avläsning nästan aldrig
#' före navigeringen). Lägger event-lyssnare (capture-fas, så vi fångar
#' händelsen innan sidans egen kod ev. stoppar den) för `click` (alla
#' element, inte bara a/button/input - se nedan) och `change` på
#' select/input - i BÅDE huvuddokumentet och alla same-origin-iframes på sidan (en nivå
#' djupt; nästlade iframes-i-iframes stöds inte i det här utkastet, precis
#' som bygg_dokument_js() i grunden). Cross-origin-iframes hoppas tyst
#' över (kan inte nås av säkerhetsskäl - samma begränsning som resten av
#' func_webbskrapning.R).
#'
#' Varje händelse taggas med `iframe`: NULL om den skedde i huvuddokumentet,
#' annars en CSS-selektor för iframen (id om den har ett, annars
#' `iframe:nth-of-type(n)`) - samma format som `iframe`-argumentet till
#' klicka_via_id()/klicka_via_text() m.fl.
#'
#' Idempotent - körs den om (t.ex. vid varje pollning) nollställs bara
#' lyssnarna, arrayen behålls. Bör köras om efter varje navigering/reload,
#' eftersom webbläsarens JS-kontext (och därmed lyssnarna) då nollställs.
#'
#' @param skrap Ett objekt skapat av starta_skrapsession().
#' @return Inget (osynligt TRUE).
#' @export
injicera_inspelning <- function(skrap) {
  if (!inherits(skrap, "skrapsession")) {
    stop("Objektet ar inte skapat av starta_skrapsession().")
  }
  rlang::check_installed("jsonlite")
  
  # Mallen används både i huvuddokumentet och (via eval i varje iframes
  # egna window) i same-origin-iframes. %IFRAME_SEL% ersätts vid körning
  # (i JS, inte via R:s sprintf) med antingen "null" eller en JSON-sträng
  # med iframens CSS-selektor.
  mall <- "
    (function() {
      var LAGERNYCKEL = '__skrap_inspelning__';
      var iframeSel = %IFRAME_SEL%;

      // Skriver till sessionStorage istället för en vanlig JS-variabel -
      // en JS-variabel (t.ex. window.top.NAGOT) lever bara så länge sidans
      // JS-kontext gör, och en riktig navigering (klick på en meny/länk,
      // till skillnad från en overlay som bara stängs) nollställer den
      // OMEDELBART - ofta innan R:s nästa kor_js()-anrop hunnit läsa av
      // vad som hann sparas. sessionStorage är garanterat bevarad över
      // navigeringar inom samma origin (webbläsarspec), så det är enda
      // sättet att inte tappa just den händelse som triggar en sidladdning.
      function spara(handelse) {
        try {
          var data = JSON.parse(sessionStorage.getItem(LAGERNYCKEL) || '[]');
          data.push(handelse);
          sessionStorage.setItem(LAGERNYCKEL, JSON.stringify(data));
        } catch (e) { /* t.ex. sessionStorage otillgängligt i sandboxad iframe */ }
      }

      // Bygger en CSS-sökväg baserad på elementets position i DOM-trädet
      // (t.ex. '#innehall > div:nth-of-type(2) > button:nth-of-type(1)'),
      // som sista utväg för element utan id/klass/text att pålitligt matcha
      // på. Klättrar uppåt tills den hittar en FÖRÄLDER med ett id och
      // ankrar där istället för vid <body> - moderna sidor saknar ofta id
      // på det klickade elementet självt, men har nästan alltid ett
      // längre upp (en sektion/container), vilket gör sökvägen mycket
      // kortare och mindre bräcklig än att alltid räkna hela vägen från
      // body. Hittas inget id alls blir det body-varianten som innan.
      // OBS: kräver att id:t faktiskt är unikt på sidan (som HTML-specen
      // egentligen kräver) - dubbletter av samma id ger fel träff.
      function sokvag(el) {
        if (!el || el.nodeType !== 1) return '';
        var delar = [];
        var cur = el;
        while (cur && cur.nodeType === 1 && cur !== document.body) {
          if (cur.id) {
            delar.unshift('#' + CSS.escape(cur.id));
            return delar.join(' > ');
          }
          var idx = 1, sib = cur;
          while ((sib = sib.previousElementSibling)) {
            if (sib.tagName === cur.tagName) idx++;
          }
          delar.unshift(cur.tagName.toLowerCase() + ':nth-of-type(' + idx + ')');
          cur = cur.parentElement;
        }
        return 'body > ' + delar.join(' > ');
      }

      // Räknar hur många element på sidan som skulle matcha varje möjlig
      // identifierare - avgör vid inspelningstillfället (då hela sidan
      // faktiskt finns i DOM:en) om text ensamt, eller klass+text, räcker
      // för att träffa EXAKT ett element. Görs bara vid själva klicket/
      // ändringen (inte i pollningsloopen), så kostnaden är försumbar.
      function textAntal(text) {
        if (!text) return -1;
        var n = 0;
        document.querySelectorAll(
          'a, button, input, select, textarea, label, div, span, li, td, th, [role]'
        ).forEach(function(e) {
          if ((e.textContent || '').trim() === text) n++;
        });
        return n;
      }
      function klassTextAntal(klass, text, tag) {
        if (!klass || !text || !tag) return -1;
        var forstaKlass = klass.split(/\\s+/)[0];
        var n = 0;
        try {
          document.querySelectorAll(tag + '.' + CSS.escape(forstaKlass)).forEach(function(e) {
            if ((e.textContent || '').trim() === text) n++;
          });
        } catch (err) { return -1; }
        return n;
      }
      // Som textAntal(), men för aria-label - avgörande för ikonknappar
      // (stäng-kryss, pilar, "tre punkter"-menyer m.fl.) som saknar synlig
      // text helt, men nästan alltid har ett aria-label för skärmläsare.
      // Sådana attribut är i praktiken mycket stabilare än genererade
      // CSS-klasser (som t.ex. Material-UI ofta hashar om mellan builds).
      function ariaAntal(aria) {
        if (!aria) return -1;
        var n = 0;
        try {
          document.querySelectorAll('[aria-label]').forEach(function(e) {
            if (e.getAttribute('aria-label') === aria) n++;
          });
        } catch (err) { return -1; }
        return n;
      }

      // Gissar om ett klick sannolikt triggar en nedladdning: antingen ett
      // uttryckligt download-attribut, eller en href som pekar på en
      // vanlig filtyp. Kan inte se knappar som triggar nedladdning via ren
      // JS utan href (t.ex. en 'Exportera'-knapp som bygger filen on the
      // fly) - de missas här och får hanteras manuellt i efterhand.
      function troligNedladdning(el, tag) {
        if (tag !== 'a') return false;
        if (el.hasAttribute('download')) return true;
        var href = el.href || '';
        return /\\.(xlsx|xls|csv|pdf|zip|docx|pptx|txt|json)(\\?|#|$)/i.test(href);
      }

      function beskriv(el) {
        var tag = el.tagName ? el.tagName.toLowerCase() : '';
        var text = (el.textContent || '').trim().slice(0, 200);
        var klass = el.className && typeof el.className === 'string' ? el.className : null;
        var aria = el.getAttribute('aria-label') || null;
        return {
          tag: tag,
          id: el.id || null,
          klass: klass,
          text: text,
          namn: el.name || null,
          typ: el.type || null,
          varde: (tag === 'select' || tag === 'input' || tag === 'textarea')
                   ? el.value : null,
          vald_text: (tag === 'select' && el.selectedIndex >= 0)
                   ? el.options[el.selectedIndex].text : null,
          iframe: iframeSel,
          sokvag: sokvag(el),
          text_antal: textAntal(text),
          klass_text_antal: klassTextAntal(klass, text, tag),
          aria_label: aria,
          aria_label_antal: ariaAntal(aria),
          href: (tag === 'a') ? (el.href || null) : null,
          nedladdning: troligNedladdning(el, tag)
        };
      }

      if (document.__skrapKlickHanterare) {
        document.removeEventListener('click', document.__skrapKlickHanterare, true);
        document.removeEventListener('change', document.__skrapAndringsHanterare, true);
      }

      document.__skrapKlickHanterare = function(e) {
        // Ingen tag-/attributfiltrering längre: SPA-ramverk (t.ex. Svelte)
        // bygger ofta 'knappar' av <div>/<span> med klick-hanterare satta
        // via addEventListener - de har varken en klickbar tagg (a/button/
        // input) eller ett onclick-attribut, och missades helt av den
        // tidigare selektorn. Klättra istället uppåt till närmaste
        // förälder med egen text om man träffat en ikon/span utan text
        // inuti 'knappen' (max 4 nivåer, för att inte hamna på en
        // container som råkar innehålla mycket annan text också).
        // Stannar ÄVEN på ett element med eget aria-label (vanligt på
        // ikonknappar utan synlig text, t.ex. en stäng-kryss) - annars
        // klättrar loopen förbi just det elementet (aria-label räknas
        // inte som textContent) och tappar den enda pålitliga
        // identifieraren knappen faktiskt hade.
        var el = e.target;
        var niva = 0;
        while (el && el !== document.body &&
               !(el.textContent || '').trim() &&
               !el.getAttribute('aria-label') &&
               niva < 4) {
          el = el.parentElement;
          niva++;
        }
        if (!el || el === document.body || el === document.documentElement) return;
        spara(Object.assign(
          { hantelse: 'click', tid: Date.now() }, beskriv(el)
        ));
      };
      document.__skrapAndringsHanterare = function(e) {
        var el = e.target;
        var tag = el.tagName ? el.tagName.toLowerCase() : '';
        if (tag !== 'select' && tag !== 'input' && tag !== 'textarea') return;
        spara(Object.assign(
          { hantelse: 'change', tid: Date.now() }, beskriv(el)
        ));
      };

      document.addEventListener('click', document.__skrapKlickHanterare, true);
      document.addEventListener('change', document.__skrapAndringsHanterare, true);
      return true;
    })();
  "
  
  # 1. Injicera i huvuddokumentet (ingen iframe -> null)
  js_huvud <- sub("%IFRAME_SEL%", "null", mall, fixed = TRUE)
  kor_js(skrap, js_huvud)
  
  # 2. Hitta alla iframes på sidan och injicera samma lyssnare i varje
  #    som går att nå (same-origin). Görs i en enda JS-körning: mallen
  #    skickas med som en textkonstant och eval:as inuti varje iframes
  #    egna window, med dess selektor insatt.
  mall_json <- jsonlite::toJSON(mall, auto_unbox = TRUE)
  js_iframes <- sprintf("
    (function() {
      var mall = %s;
      var iframes = document.querySelectorAll('iframe');
      var resultat = [];
      iframes.forEach(function(fr, idx) {
        var sel = fr.id ? ('#' + fr.id) : ('iframe:nth-of-type(' + (idx + 1) + ')');
        try {
          if (!fr.contentDocument) { resultat.push({selector: sel, ok: false}); return; }
          var kod = mall.replace('%%IFRAME_SEL%%', JSON.stringify(sel));
          fr.contentWindow.eval(kod);
          resultat.push({selector: sel, ok: true});
        } catch (e) {
          resultat.push({selector: sel, ok: false, fel: String(e)});
        }
      });
      return JSON.stringify(resultat);
    })();
  ", mall_json)
  
  kor_js(skrap, js_iframes)
  invisible(TRUE)
}

# --- 2. Läs av (och töm) inspelningsarrayen --------------------------------

#' Läs av alla nya inspelade händelser och töm arrayen i webbläsaren
#'
#' @param skrap Ett objekt skapat av starta_skrapsession().
#' @return En tibble, en rad per händelse (kan ha 0 rader).
#' @export
lasa_av_inspelning <- function(skrap) {
  if (!inherits(skrap, "skrapsession")) {
    stop("Objektet ar inte skapat av starta_skrapsession().")
  }
  rlang::check_installed(c("tibble", "purrr"), reason = "for att lasa av inspelningen")
  
  js <- "
  (function() {
    var LAGERNYCKEL = '__skrap_inspelning__';
    var data = JSON.parse(sessionStorage.getItem(LAGERNYCKEL) || '[]');
    sessionStorage.removeItem(LAGERNYCKEL);
    return JSON.stringify(data);
  })();
  "
  raw <- kor_js(skrap, js)
  if (is.null(raw) || !nzchar(raw)) {
    return(tibble::tibble(
      hantelse = character(), tid = double(), tag = character(),
      id = character(), klass = character(), text = character(),
      namn = character(), typ = character(), varde = character(),
      vald_text = character(), iframe = character(), sokvag = character(),
      text_antal = double(), klass_text_antal = double(),
      aria_label = character(), aria_label_antal = double(),
      href = character(), nedladdning = logical()
    ))
  }
  
  handelser <- jsonlite::fromJSON(raw, simplifyDataFrame = FALSE)
  if (length(handelser) == 0) {
    return(tibble::tibble(
      hantelse = character(), tid = double(), tag = character(),
      id = character(), klass = character(), text = character(),
      namn = character(), typ = character(), varde = character(),
      vald_text = character(), iframe = character(), sokvag = character(),
      text_antal = double(), klass_text_antal = double(),
      aria_label = character(), aria_label_antal = double(),
      href = character(), nedladdning = logical()
    ))
  }
  
  purrr::map_dfr(handelser, function(h) {
    tibble::tibble(
      hantelse = h$hantelse %||% NA_character_,
      tid = h$tid %||% NA_real_,
      tag = h$tag %||% NA_character_,
      id = h$id %||% NA_character_,
      klass = h$klass %||% NA_character_,
      text = h$text %||% NA_character_,
      namn = h$namn %||% NA_character_,
      typ = h$typ %||% NA_character_,
      varde = h$varde %||% NA_character_,
      vald_text = h$vald_text %||% NA_character_,
      iframe = h$iframe %||% NA_character_,
      sokvag = h$sokvag %||% NA_character_,
      text_antal = h$text_antal %||% NA_real_,
      klass_text_antal = h$klass_text_antal %||% NA_real_,
      aria_label = h$aria_label %||% NA_character_,
      aria_label_antal = h$aria_label_antal %||% NA_real_,
      href = h$href %||% NA_character_,
      nedladdning = h$nedladdning %||% FALSE
    )
  })
}

`%||%` <- function(x, y) if (is.null(x)) y else x

#' Kör en JS-sträng upprepade gånger tills den returnerar TRUE eller tiden
#' går ut
#'
#' Används av de kor_js()-baserade reservlägena i det genererade skriptet
#' (element utan id/klass/text, matchade via DOM-sökväg), så att element
#' som laddas in asynkront (efter en AJAX-driven ändring, en
#' SPA-omrendering osv.) hinner dyka upp innan vi ger upp - utan att du
#' manuellt behöver lägga in en väntan. Motsvarar det `vanta = TRUE` redan
#' gör inbyggt för klicka_via_id()/klicka_via_text() m.fl.
#'
#' Går INTE att lösa med en synkron väntloop inuti själva JS-strängen -
#' webbläsarens JS-tråd är enkeltrådad, så en spinnande loop där skulle
#' blockera sidan från att någonsin hinna rendera det vi väntar på. Därför
#' pollas det istället upprepade gånger från R-sidan, med en paus emellan
#' som låter webbläsaren faktiskt hinna jobba.
#'
#' @param skrap Ett objekt skapat av starta_skrapsession().
#' @param js En JS-sträng vars sista uttryck ska vara ett booleskt värde -
#'   TRUE när det eftersökta elementet finns och åtgärden utförts.
#' @param timeout Max väntetid i sekunder.
#' @param intervall Paus mellan varje försök i sekunder.
#' @return TRUE om js någon gång returnerade TRUE inom timeout, annars FALSE.
#' @export
vanta_kor_js <- function(skrap, js, timeout = 10, intervall = 0.2) {
  deadline <- Sys.time() + timeout
  repeat {
    resultat <- kor_js(skrap, js)
    if (isTRUE(resultat)) return(TRUE)
    if (Sys.time() >= deadline) return(FALSE)
    Sys.sleep(intervall)
  }
}

# --- 3. Generera R-kod från inspelade händelser -----------------------------

#' Bygg ett R-uttryck (som text) för en enskild inspelad händelse
#'
#' Prioritetsordning: id först (unikt per HTML-spec), därefter aria-label
#' (om unikt på sidan) - avgörande för ikonknappar utan synlig text, som
#' annars bara kan identifieras via den bräckliga DOM-sökvägen - därefter
#' den svagaste identifieraren som vid inspelningstillfället faktiskt
#' bekräftats vara unik på sidan (text ensamt, sedan klass+text) - annars
#' kor_js() med den inspelade DOM-sökvägen som sista utväg. Svelte-typ
#' "scoped"-klasser (t.ex. "svelte-zhv9wr") filtreras bort eftersom de är
#' instabila mellan builds.
#'
#' @param rad En rad (som lista) från lasa_av_inspelning().
#' @return En textrad med R-kod, eller NA om händelsen ska hoppas över.
#' @export
generera_rad <- function(rad) {
  stad_klass <- function(klass) {
    if (is.na(klass) || !nzchar(klass)) return(NA_character_)
    delar <- strsplit(klass, "\\s+")[[1]]
    delar <- delar[!grepl("^svelte-[a-z0-9]+$", delar)]
    if (length(delar) == 0) return(NA_character_)
    paste(delar, collapse = " ")
  }
  
  # Bygger ", iframe = \"...\"" om händelsen skedde i en iframe, annars "".
  iframe_arg <- function(iframe) {
    if (is.na(iframe) || !nzchar(iframe)) return("")
    sprintf(', iframe = "%s"', iframe)
  }
  
  # Städar text/värden innan de läggs in i en JS-strängliteral (dubbla
  # citattecken) inuti kor_js()-fallbackerna.
  js_stad <- function(x) {
    if (is.na(x)) return("")
    x <- gsub("\\\\", "\\\\\\\\", x)
    gsub('"', '\\\\"', x)
  }

  # Städar ett aria-label-värde för infogning i en genererad kodrad av
  # formen 'klicka_via_id(skrap, \'[aria-label="VÄRDE"]\')' - koden runt
  # om använder enkla citattecken (R-strängen) med dubbla citattecken
  # inuti (CSS-attributvärdet), så bakstreck, enkla och dubbla citattecken
  # maste escapas (bakstreck-escape ar giltigt i bada sammanhangen).
  aria_stad <- function(x) {
    if (is.na(x)) return("")
    x <- gsub("\\\\", "\\\\\\\\", x)
    x <- gsub("'", "\\\\'", x)
    gsub('"', '\\\\"', x)
  }

  if (rad$hantelse == "click") {
    klass_stadad <- stad_klass(rad$klass)
    ifr <- iframe_arg(rad$iframe)
    kor_js_fallback <- function() {
      if (!is.na(rad$sokvag) && nzchar(rad$sokvag)) {
        sprintf(
          'traff <- vanta_kor_js(skrap, \'var el = document.querySelector("%s"); if (el) el.click(); !!el;\')  # OBS: sökväg via DOM-position (tag=%s) - bräckligt, verifiera\nstopifnot("Hittade inte klickmål (sökväg: %s)" = isTRUE(traff))',
          js_stad(rad$sokvag), rad$tag, js_stad(rad$sokvag)
        )
      } else {
        sprintf(
          '# OBS: kunde inte generera klick automatiskt (tag=%s, ingen id/klass/text/sökväg) - komplettera manuellt',
          rad$tag
        )
      }
    }
    
    # Prioritetsordning: id (alltid unikt per HTML-spec) - därefter aria-label
    # (om unikt) - avgörande för ikonknappar utan synlig text (stäng-kryss,
    # pilar, "tre punkter"-menyer m.fl.), som annars bara kan identifieras
    # via den bräckliga DOM-sökvägen. aria-label är dessutom ofta stabilare
    # än genererade CSS-klasser, som t.ex. Material-UI kan hasha om mellan
    # driftsättningar - därefter den SVAGASTE identifieraren som ändå
    # faktiskt är unik på sidan, kollat vid inspelningstillfället
    # (text_antal/klass_text_antal). Är inget av ovan unikt (t.ex. fem
    # "Nästa"-knappar) ger ingen av bibliotekets funktioner en pålitlig
    # träff - då används kor_js() med den inspelade DOM-sökvägen istället,
    # som är garanterat unik eftersom den bygger på elementets faktiska
    # position (men känslig för att den positionen kan ändras mellan
    # inspelning och körning, se README).
    if (!is.na(rad$id) && nzchar(rad$id)) {
      return(sprintf('klicka_via_id(skrap, "#%s"%s)', rad$id, ifr))
    }
    if (!is.na(rad$aria_label) && nzchar(rad$aria_label) &&
        !is.na(rad$aria_label_antal) && rad$aria_label_antal == 1) {
      return(sprintf(
        'klicka_via_id(skrap, \'[aria-label="%s"]\'%s)',
        aria_stad(rad$aria_label), ifr
      ))
    }
    if (!is.na(rad$text) && nzchar(rad$text) &&
        !is.na(rad$text_antal) && rad$text_antal == 1) {
      return(sprintf('klicka_via_text(skrap, "%s"%s)', rad$text, ifr))
    }
    if (!is.na(klass_stadad) && !is.na(rad$text) && nzchar(rad$text) &&
        !is.na(rad$klass_text_antal) && rad$klass_text_antal == 1) {
      forsta_klass <- strsplit(klass_stadad, " ")[[1]][1]
      return(sprintf(
        'klicka_via_klass_och_text(skrap, klass = "%s", text = "%s", tag = "%s"%s)',
        forsta_klass, rad$text, rad$tag, ifr
      ))
    }
    # Inget av ovan var unikt bekräftat, men bara i huvuddokumentet -
    # kor_js() med iframes stöds inte i det här utkastet.
    if (is.na(rad$iframe)) {
      return(kor_js_fallback())
    }
    return(sprintf(
      '# OBS: klick i iframe (%s) utan garanterat unik id/text/klass - komplettera manuellt',
      rad$iframe
    ))
  }
  
  # select/input-ändringar: selenider::s() vet inte hur den ska gå ner i en
  # iframe (det stödet finns bara i de egna klicka_/kor_js-funktionerna),
  # så för händelser inuti en iframe genereras en kor_js()-baserad rad
  # istället för en selenider-kedja.
  if (rad$hantelse == "change" && rad$tag == "select") {
    if (!is.na(rad$iframe) && nzchar(rad$iframe)) {
      return(sprintf(
        '# OBS: select i iframe (%s) - selenider::s() ser inte in i iframes.\n# Sätt värdet manuellt via kor_js(skrap, ...) med bygg_dokument_js(iframe = "%s"),\n# t.ex. genom att bygga vidare på hamta_select_options()-mönstret. Valt: "%s"',
        rad$iframe, rad$iframe, rad$vald_text
      ))
    }
    if (!is.na(rad$id) && nzchar(rad$id)) {
      return(sprintf(
        'selenider::s(skrap$session, "#%s") |> selenider::elem_select("%s")',
        rad$id, rad$vald_text
      ))
    }
    # Utan id: kör via kor_js() istället - matchar på DOM-sökväg och väljer
    # optionen vars synliga text stämmer (mer robust än att gissa options
    # underliggande value-attribut, som inte spelades in).
    if (!is.na(rad$sokvag) && nzchar(rad$sokvag)) {
      return(sprintf(
        'traff <- vanta_kor_js(skrap, \'var el = document.querySelector("%s"); var opt = el ? [...el.options].find(function(o){ return o.text.trim() === "%s"; }) : null; if (opt) { el.value = opt.value; el.dispatchEvent(new Event("change", {bubbles:true})); } !!opt;\')  # OBS: sökväg via DOM-position - bräckligt, verifiera\nstopifnot("Hittade inte select (sökväg: %s)" = isTRUE(traff))',
        js_stad(rad$sokvag), js_stad(rad$vald_text), js_stad(rad$sokvag)
      ))
    }
    return(sprintf(
      '# OBS: select utan id/sökväg - komplettera CSS-selektor manuellt. Valt: "%s"',
      rad$vald_text
    ))
  }
  
  if (rad$hantelse == "change") {
    if (!is.na(rad$iframe) && nzchar(rad$iframe)) {
      return(sprintf(
        '# OBS: inmatningsfält i iframe (%s) - komplettera manuellt via kor_js(). Värde: "%s"',
        rad$iframe, rad$varde
      ))
    }
    if (!is.na(rad$id) && nzchar(rad$id)) {
      return(sprintf(
        'selenider::s(skrap$session, "#%s") |> selenider::elem_set_value("%s")',
        rad$id, rad$varde
      ))
    }
    if (!is.na(rad$sokvag) && nzchar(rad$sokvag)) {
      return(sprintf(
        'traff <- vanta_kor_js(skrap, \'var el = document.querySelector("%s"); if (el) { el.value = "%s"; el.dispatchEvent(new Event("input", {bubbles:true})); el.dispatchEvent(new Event("change", {bubbles:true})); } !!el;\')  # OBS: sökväg via DOM-position - bräckligt, verifiera\nstopifnot("Hittade inte inmatningsfält (sökväg: %s)" = isTRUE(traff))',
        js_stad(rad$sokvag), js_stad(rad$varde), js_stad(rad$sokvag)
      ))
    }
    return(sprintf(
      '# OBS: inmatningsfält utan id/sökväg - komplettera CSS-selektor manuellt. Värde: "%s"',
      rad$varde
    ))
  }
  
  NA_character_
}

#' Generera ett komplett R-skript från en logg av inspelade händelser
#'
#' Klick som ser ut att trigga en nedladdning (identifierat vid
#' inspelningstillfället - se `troligNedladdning()` i injicera_inspelning(),
#' `download`-attribut eller en href mot en vanlig filtyp) wrappas
#' automatiskt i `hamta_nedladdning()` istället för ett bart klick, och
#' numreras (`fil_1`, `fil_2`, ...) om flera förekommer.
#'
#' @param handelser Tibble från lasa_av_inspelning() (kan vara flera
#'   sammanslagna omgångar).
#' @param url Valfri startadress att lägga in en open_url()-rad för.
#' @param nedladdningsmapp Mapp som läggs in som en `nedladdningsmapp <- ...`
#'   -rad i skriptets huvud, bara om minst en nedladdning spelades in.
#'   Default en platshållarsökväg att byta ut.
#' @return En sammanhängande textsträng med R-kod.
#' @export
generera_skript <- function(handelser, url = NULL,
                            nedladdningsmapp = "C:/temp/nedladdningar") {
  if (nrow(handelser) == 0) {
    return("# Inga händelser inspelade ännu.")
  }
  rlang::check_installed("purrr", reason = "for att generera skriptet")
  
  # Numrerar nedladdningarna i den ordning de spelades in (1, 2, 3, ...),
  # så flera nedladdningar i samma inspelning får unika variabelnamn
  # (fil_1, fil_2, ...) i det genererade skriptet.
  handelser$nedladdning_nr <- cumsum(
    handelser$hantelse == "click" & handelser$nedladdning
  )
  
  rad_till_kod <- function(rad) {
    uttryck <- generera_rad(rad)
    if (is.na(uttryck)) return(NA_character_)
    # Bara wrappa faktisk kod - inte # OBS:-kommentarer där inget kunde
    # genereras (då finns ju inget klick att trigga nedladdningen med).
    if (!identical(rad$hantelse, "click") || !isTRUE(rad$nedladdning) ||
        grepl("^\\s*#", uttryck)) {
      return(uttryck)
    }
    lank <- if (is.na(rad$href)) "okänd" else rad$href
    sprintf(
      'fil_%d <- hamta_nedladdning(\n  skrap,\n  trigger = function() {\n    %s\n  },\n  nedladdningsmapp = nedladdningsmapp\n)  # OBS: satt monster (t.ex. "\\\\.xlsx$") om flera filtyper kan laddas ner. Länk: %s',
      rad$nedladdning_nr, gsub("\n", "\n    ", uttryck), lank
    )
  }
  
  rader <- purrr::map_chr(purrr::transpose(handelser), rad_till_kod)
  rader <- rader[!is.na(rader)]
  
  har_nedladdningar <- any(handelser$nedladdning, na.rm = TRUE)
  
  huvud <- c(
    "# Automatiskt genererat utkast. klicka_via_*()-anropen väntar redan in",
    "# element internt (vanta = TRUE): både en eventuell sidnavigering och,",
    "# därefter, att sidans DOM slutat ändra sig (vanta_pa_stabil_dom() - även",
    "# SPA:er/inbäddade lösningar som Qlik fångas upp, inte bara klassiska",
    "# postbacks). kor_js()-reservlägena pollar på samma sätt via",
    "# vanta_kor_js() - så väntan sköts i regel automatiskt. Kontrollera",
    "# ändå # OBS:-raderna nedan. Har sidan kontinuerligt uppdaterande",
    "# innehåll (en klocka, en auto-uppdaterande widget) som gör att",
    "# DOM-väntan aldrig blir 'stabil', sätt dom_stabil_tid = NULL på",
    "# klick i den delen av skriptet.",
    "",
    "library(skrapa)",
    "",
    "skrap <- starta_skrapsession(headless = FALSE)",
    if (!is.null(url)) sprintf('selenider::open_url("%s", session = skrap$session)', url),
    if (har_nedladdningar) sprintf(
      'nedladdningsmapp <- "%s"  # OBS: byt till önskad mapp',
      nedladdningsmapp
    ),
    ""
  )
  
  paste(c(huvud, rader, "", "stang_skrapsession(skrap)"), collapse = "\n")
}

# --- 4. Shiny-gadget (lokal kontrollpanel) ---------------------------------

#' Kör inspelningsgadgeten
#'
#' Startar en synlig skrapsession, injicerar inspelnings-JS:en, och visar
#' en liten kontrollpanel (miniUI-gadget) med en pollningstimer som var
#' 500:e ms läser av nya händelser och uppdaterar en live-logg samt det
#' genererade skriptet.
#'
#' När du trycker **Done** skrivs det genererade skriptet ut i konsolen med
#' `cat()`, och kopieras till urklipp (kräver paketet `clipr` - saknas det,
#' eller är urklipp otillgängligt i miljön, skrivs bara ett meddelande om
#' det istället, skriptet skrivs ut ändå).
#'
#' @param url Valfri adress att öppna direkt vid start.
#' @param nedladdningsmapp Läggs in i det genererade skriptets huvud som
#'   `nedladdningsmapp <- ...`, om minst en nedladdning spelas in.
#' @param ... Vidarebefordras till starta_skrapsession() (t.ex. browser_path).
#'
#' @examples
#' \dontrun{
#' skript <- kor_inspelningsgadget(url = "https://exempel.se/formular")
#' cat(skript)
#' }
#' @export
kor_inspelningsgadget <- function(url = NULL, nedladdningsmapp = "C:/temp/nedladdningar", ...) {
  rlang::check_installed(
    c("shiny", "miniUI", "dplyr", "tibble", "purrr"),
    reason = "for att kora inspelningsgadgeten (kor_inspelningsgadget())"
  )
  
  ui <- miniUI::miniPage(
    miniUI::gadgetTitleBar("Skrapinspelning"),
    miniUI::miniTabstripPanel(
      miniUI::miniTabPanel(
        "Logg", icon = shiny::icon("list"),
        miniUI::miniContentPanel(
          shiny::actionButton("stoppa_inspelning", "Pausa/återuppta inspelning"),
          shiny::textOutput("status_rad"),
          shiny::uiOutput("logg_tabell")
        )
      ),
      miniUI::miniTabPanel(
        "Genererad kod", icon = shiny::icon("code"),
        miniUI::miniContentPanel(
          shiny::verbatimTextOutput("kod_output")
        )
      )
    )
  )
  
  server <- function(input, output, session) {
    
    skrap <- starta_skrapsession(headless = FALSE, view = FALSE, ...)
    tryCatch(stang_extra_flikar(skrap), error = function(e) {
      message("[inspelning] kunde inte stänga extra-flik: ", conditionMessage(e))
    })
    if (!is.null(url)) {
      selenider::open_url(url, session = skrap$session)
    }
    injicera_inspelning(skrap)
    
    pausad <- shiny::reactiveVal(FALSE)
    senaste_fel <- shiny::reactiveVal(NULL)
    handelser <- shiny::reactiveVal(
      tibble::tibble(
        hantelse = character(), tid = double(), tag = character(),
        id = character(), klass = character(), text = character(),
        namn = character(), typ = character(), varde = character(),
        vald_text = character(), iframe = character(), sokvag = character(),
        text_antal = double(), klass_text_antal = double(),
        aria_label = character(), aria_label_antal = double(),
        href = character(), nedladdning = logical()
      )
    )
    
    shiny::observeEvent(input$stoppa_inspelning, {
      pausad(!pausad())
    })
    
    timer <- shiny::reactiveTimer(500)
    shiny::observe({
      timer()
      if (isTRUE(pausad())) return()
      
      # Återinjicera vid varje tick - idempotent, och avgörande efter en
      # sidladdning (t.ex. cookiebanner-val som gör en full reload), då
      # webbläsarens JS-kontext nollställs och lyssnaren från förra sidan
      # inte längre finns kvar. Fel loggas (istället för att tystas) så att
      # ihållande problem (t.ex. trasig exekveringskontext eller att sidan
      # bytt CDP-target) syns i R-konsolen istället för att bara se ut som
      # "inget registreras".
      tryCatch(
        injicera_inspelning(skrap),
        error = function(e) {
          senaste_fel(paste("injicera_inspelning:", conditionMessage(e)))
          message("[inspelning] injicera_inspelning fel: ", conditionMessage(e))
        }
      )
      
      nya <- tryCatch(
        lasa_av_inspelning(skrap),
        error = function(e) {
          senaste_fel(paste("lasa_av_inspelning:", conditionMessage(e)))
          message("[inspelning] lasa_av_inspelning fel: ", conditionMessage(e))
          NULL
        }
      )
      if (!is.null(nya) && nrow(nya) > 0) {
        handelser(dplyr::bind_rows(handelser(), nya))
      }
    })
    
    output$status_rad <- shiny::renderText({
      fel <- senaste_fel()
      if (is.null(fel)) "Status: OK" else paste("Status: senaste fel -", fel)
    })
    
    output$logg_tabell <- shiny::renderUI({
      df <- handelser() |>
        dplyr::select(hantelse, tag, id, klass, text, aria_label, vald_text, varde, iframe, sokvag)
      if (nrow(df) == 0) return(shiny::tags$em("Inga händelser inspelade ännu."))
      
      kolumner <- names(df)
      cell_stil <- paste(
        "white-space: nowrap; overflow: hidden; text-overflow: ellipsis;",
        "max-width: 220px; display: block;"
      )
      
      rubrikrad <- shiny::tags$tr(
        lapply(kolumner, function(k) {
          shiny::tags$th(
            k,
            style = "text-align: left; padding: 4px 8px; border-bottom: 2px solid #ccc; white-space: nowrap;"
          )
        })
      )
      datarader <- lapply(seq_len(nrow(df)), function(i) {
        shiny::tags$tr(
          lapply(kolumner, function(k) {
            varde_i <- df[[k]][i]
            varde_txt <- if (is.na(varde_i)) "" else as.character(varde_i)
            shiny::tags$td(
              style = "padding: 4px 8px; border-bottom: 1px solid #eee; max-width: 220px;",
              shiny::tags$div(varde_txt, title = varde_txt, style = cell_stil)
            )
          })
        )
      })
      
      shiny::tags$table(
        style = "width: 100%; border-collapse: collapse; table-layout: fixed; font-size: 12px;",
        shiny::tags$thead(rubrikrad),
        shiny::tags$tbody(datarader)
      )
    })
    
    output$kod_output <- shiny::renderText({
      generera_skript(handelser(), url = url, nedladdningsmapp = nedladdningsmapp)
    })
    
    shiny::observeEvent(input$done, {
      stang_skrapsession(skrap)
      skript <- generera_skript(handelser(), url = url, nedladdningsmapp = nedladdningsmapp)
      
      cat(skript, "\n")

      # clipr::write_clip() ger (pa Windows, via utils::writeClipboard())
      # ibland en VARNING istallet for ett fel om urklipp tillfalligt ar
      # upptaget av ett annat program (t.ex. en urklippshanterare, RStudios
      # egen viewer, eller en antivirusprodukt som haller det kort) - koden
      # fortsatte da och pastod felaktigt att kopieringen lyckats. Fangar nu
      # upp varningen, gor ett andra forsok efter en kort paus, och rapporterar
      # arligt om det fortfarande inte gick.
      forsok_kopiera <- function() {
        lyckades <- TRUE
        withCallingHandlers(
          clipr::write_clip(skript),
          warning = function(w) {
            lyckades <<- FALSE
            invokeRestart("muffleWarning")
          }
        )
        lyckades
      }

      kopierat <- FALSE
      if (rlang::is_installed("clipr") && clipr::clipr_available()) {
        kopierat <- tryCatch(forsok_kopiera(), error = function(e) FALSE)
        if (!kopierat) {
          Sys.sleep(0.3)
          kopierat <- tryCatch(forsok_kopiera(), error = function(e) FALSE)
        }
      }

      if (kopierat) {
        message("Skriptet ovan är kopierat till urklipp.")
      } else if (rlang::is_installed("clipr") && clipr::clipr_available()) {
        message(
          "Skriptet ovan kunde INTE kopieras till urklipp - urklipp var ",
          "(aven efter ett andra forsok) upptaget av ett annat program ",
          "(t.ex. en urklippshanterare eller antivirusprodukt). Kopiera ",
          "manuellt fran konsolen ovan."
        )
      } else {
        message(
          "Skriptet ovan kunde INTE kopieras till urklipp (paketet 'clipr' ",
          "saknas eller urklipp är otillgängligt i den här miljön) - kopiera ",
          "manuellt från konsolen ovan."
        )
      }
      
      shiny::stopApp(skript)
    })
    shiny::observeEvent(input$cancel, {
      stang_skrapsession(skrap)
      shiny::stopApp(invisible(NULL))
    })
    session$onSessionEnded(function() {
      tryCatch(stang_skrapsession(skrap), error = function(e) NULL)
    })
  }
  
  shiny::runGadget(ui, server, viewer = shiny::paneViewer())
}