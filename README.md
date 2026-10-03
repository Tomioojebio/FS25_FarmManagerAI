# FS25 FarmManagerAI — vývoj autonomního družstva

Aktuální výchozí verze: **0.20.49.0**. Hra: Farming Simulator 25 1.15.0.0; mapa: Karpatský venkov; s Courseplay.

**Stav: vývojový prototyp, nikoli hotový autonomní systém.** Offline testy neprokazují funkční přejezdy, zapřahání, sklizeň ani hutnění uvnitř GIANTS enginu. Neinstalujte do jediného existujícího savegame bez zálohy.

## Cílové chování

Zapnout AUTO → zjistit stav polí, zvířat, techniky a zásob → vytvořit pracovní plán → zvolit kompatibilní soupravy → bezpečně zapřáhnout → najít průjezdnou trasu po celé mapě → fyzicky vykonat práci → doplnit/odvézt materiál → vrátit a odstavit techniku. Hráč je manažer, nikoli manuální řidič.

## Hlavní otevřené závady

1. Skutečné přejezdy musí být potvrzené GIANTS runtime; pouhý souhlas AI nebo Courseplay nestačí.
2. LEXION 6900 se může po převzetí AI nerozjet; harvest cycle není ověřený.
3. Soupravy a stroje v jámě potřebují ověřenou geometrii vjezdu, průjezdné stopy a koordinaci více strojů.
4. Zapřahání, hnojení, vápnění, odvoz a návraty dosud nejsou systémově ověřené.
5. Testy musejí rozlišit syntaxi, simulaci a skutečné testy ve hře.

Distribuční název výsledného modu vždy přesně `FS25_FarmManagerAI.zip`. Verze patří do `modDesc.xml`.
