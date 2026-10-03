# FS25 FarmManagerAI — autonomní zemědělské družstvo (vývoj)

**Karpatský venkov + Farming Simulator 25 1.15 + Courseplay; verze 0.20.50.0.** Projekt není hotový bezobslužný systém. GIANTS engine nelze v CI spustit a 607 offline testů nezaručuje skutečné projetí tras a úkonů.

Cíl: zapnout AUTO, automaticky naplánovat práci, vybrat a zapřáhnout soupravy, provést přejezd přes silniční síť, fyzicky pracovat, odvézt materiál a vrátit stroje. V režimu předsedy nemá být nutné ručně řídit techniku. Současné chyby zahrnují nehybný LEXION 6900 při sklizni, chybějící dostupné přejezdy pro větší soupravy a hutnění více traktorů v jedné jámě.

## Sestavení a stažení

Po každém push do `main` běží [GitHub Actions](https://github.com/Tomioojebio/FS25_FarmManagerAI/actions/workflows/qa.yml). Otevři poslední úspěšný běh a v části **Artifacts** stáhni `FS25_FarmManagerAI-build`. Uvnitř najdeš **`FS25_FarmManagerAI.zip`**, který se instaluje beze změny názvu přímo do `Documents/My Games/FarmingSimulator2025/mods/` (ne rozbalit). Na farmě používej nejprve kopii savegame.

Pro lokální QA: `python3 developer/run_lua.py` s dostupnou knihovnou Lua 5.4. Pro sestavení: `python3 developer/build.py /tmp/FS25_FarmManagerAI.zip`.

## Poslední změny

- 0.20.49.0: základ skutečného plánování po silničních spline a potvrzování dílčích dojezdů.
- **0.20.50.0: krátké fyzicky ověřované napojení ze dvora na cestu a výjezd k cíli do 32 m; nebezpečné / neověřené průjezdy dál odmítáme.**
- Offline regresní testy: 607. **In-game validace: zatím neprovedena.**

Výstupní instalační jméno je vždy přesně **`FS25_FarmManagerAI.zip`**, verze pouze v `modDesc.xml`.
