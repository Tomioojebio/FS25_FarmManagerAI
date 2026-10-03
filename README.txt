FARM MANAGER AI 0.20.49.0 — CELÁ SILNIČNÍ SÍŤ / VÝVOJOVÉ VYDÁNÍ
=================================================================
Po selhání verzí 0.20.43–0.20.48 jsme změnili základ přejezdů. Skutečné
GIANTS road splines se nyní používají k plánování po celé mapě místo limitu
500 m kolem dvora. Souvislé silnice lze rozdělit na ověřované dílčí přejezdy.
U vzdáleného cíle bez nalezené trasy se nesmí donekonečna opakovat GIANTS
příkaz na kilometrový bod; alternativu může jednou zkusit Courseplay.

NENÍ TO OVĚŘENÁ AUTONOMNÍ FARMA. Tato verze obsahuje cílenou opravu
navigačního jádra, nikoli potvrzení fyzického rozjezdu kombajnu ani všech
pracovních řetězců. Jedině kopie uložené farmy. Diagnostika Alt+D.
Změny a omezení: docs/REALNA_NAVIGACE_02049_CZ.md.

FARM MANAGER AI 0.20.48.0 – HOTFIX MOTORU A PŘEDÁVÁNÍ COURSEPLAY

FARM MANAGER AI 0.20.47.0 — OBNOVA PRACOVNÍCH CYKLŮ (VÝVOJOVÁ VERZE)
=====================================================================
Celý mod zůstává zachovaný; přidán modul FMASelfHealing. Automatická obnova
je podmíněna OPRAVDOVOU změnou situace a dvěma omezenými pokusy. Nepřepisuje
majitelem zastavené úlohy, nevydává pouhé přijetí AI příkazu za skutečnou práci.

Aktuálně potvrzené přímo hrou: XERION se dříve na dvoře pohyboval. Ostatní
fyzické pracovní cykly dosud NELZE označit za hotové.
Nové úpravy podle živého TRACE: CP spouštění ze zadního vjezdu jámy je
zablokováno, dokud není fyzicky ověřený správný směr. Traktor už uvnitř
jámy může dostat kontrolované průjezdy vlastním řidičem, pokud je rovný,
v prostoru a má bezpečný volný jízdní pás. Při falešném AI dojezdu CP
hutnění nezačne. Nehybný LEXION nedostane neomezené další dlouhé trasy;
jakmile dojde k reálnému přemístění, je povolen omezený nový pokus.
Automatické opětovné zvážení zakázky probíhá i po změně polohy blokovaného
zápřahu. Zůstávají diagnostické reporty Alt+D a Alt+M rozhraní.

Nepotvrzené: plné autonomní dokončení sklizně a převoz lišty, bezpečné
vyhýbání všem reálným objektům, auto krmení bez GIANTS AI triggerů, zajíždění
bez naučených parkovacích bodů a úplné fyzické zapřahání. Neexistuje záruka,
že GIANTS engine přijme každou vytvořenou úlohu. Zkušební použití POUZE
na KOPII uložené farmy; originální savegame tímto ZIPem netestovat.
Podrobný rozbor: docs/OBNOVA_DRUZSTVA_02047_CZ.md.

FARM MANAGER AI 0.20.42.0 — DOČASNÝ VÝVOJOVÝ AUTOTEST
=========================================================
Toto vydání obsahuje dočasnou FMADevLab.lua laboratoř; před stabilním vydáním odstranit.
Není potřeba složitě testovat ručně: po načtení mapy automaticky sleduje skutečné
polohy, motor, řídicí AI, zablokování, rezervace a pracovní objednávky.
Každých ~90 sekund (poprvé po ~24 s) automaticky přepisuje JEDEN kompletní
FS25_FarmManagerAI_REPORT.txt do plochy/profilu. Při odchodu z mapy také exportuje.
Stačí hrát a pak poslat TENTO JEDINÝ REPORT; Alt+D je okamžitý export na požádání.

VOLITELNÁ SKUTEČNÁ FYZICKÁ ZKOUŠKA: JEN NA KOPII ULOŽENÉ HRY!
Alt+M -> PROBLÉMY -> VÝVOJ: TEST MOTORU A JÍZDY. S vypnutým AUTO vybere
vlastní volný samostatný traktor alespoň 25 m od zjištěných budov a strojů;
když nenajde vyhovující prostor, NEROZJEDE NIC. Pokud ho najde, zkusí
start motoru, asi 1.4m vpřed, pak zpět; při chybě pohybu/AI/hráči zastaví.
Výsledky v kapitole 01B_DEV_AUTOTEST. Nejde o kompletní test kolizí ani práce.
Fyzické výsledky mohou být potvrzené POUZE na běžícím GIANTS FS25 enginu.
Dokumentace docs/DEV_AUTOTEST_02042_CZ.md.

FARM MANAGER AI 0.20.41.0 – JEDNOTNÉ ŘÍZENÍ DRUŽSTVA
====================================================
Celkový rozsah a přejímací scénáře viz docs/ARCHITEKTURA_RIZENI_DRUZSTVA_02041_CZ.md.
Nově jednotný arbitr GIANTS/CP/FMA, ochrana rezervací a závodů ukončení úloh.
Název ZIP přesně FS25_FarmManagerAI.zip. Ovládání E/Enter/ESC beze změn.
558 offline testů; skutečná fyzická funkčnost všech cyklů musí být potvrzena FS25.

FarmManagerAI 0.20.40.0 — třetí vlastní fyzický řidič
========================================================
GIANTS AI a Courseplay plní většinu úloh; FMAOwnDriver nyní zajišťuje vlastní
fyzické lokální manévry k závěsům a po chybě CP v ověřené silážní jámě.
Pohyb používá GIANTS fyziku, ne teleport. Při selhání ohlásí chybu.
Žádné funkce neoznačujeme za herně ověřené bez testu ve FS25.
Všechny detaily: docs/TRI_AI_FYZICKY_RIDIC_02040_CZ.md
Rozhraní: Alt+M, Alt+H a Alt+D. Alt+P není součástí manageru.

FARM MANAGER AI 0.20.35.0 - fyzické ověřování hutnění a pracovní sekce

Nově: AI/CP request se nesmí tvářit jako hotová práce. Bunker watchdog
ověřuje skutečné převzetí AI, stav motoru a fyzický přesun/zhutnění.
Pokud nedojde do 10 sekund k převzetí stroje nebo do 35 sekund k fyzickému
pohybu, úloha je označena chybou a uvolní soupravu pro další pokus.
GIANTS startMotor se požádá jen pro volnou vhodnou soupravu.

Courseplay hutnění se spouští nejvýš 12 m od ústí jámy, jinak nejprve
proběhne samostatný ověřený příjezd. Při opakování může manager zvolit
opačný vjezd. Jízdu musí potvrdit FS25, není simulovaná.

Po skutečném zhutnění je vyžádán fyzický návrat do výchozího/naučeného
stání. Pokud nelze zaparkovat, zobrazí se konkrétní problém a stav
nepředstírá dokončené parkování.

Terminál Alt+M: Přehled, Vše, Pole, Sklizeň, Zvířata, Siláž,
Technika, Problémy, Mapa, Více. Přidány jednoduché obrázkové ikonky.
Ovládání Enter (motor), ESC a kamera ve hře se nemění.
U skladovaných balíků se čte skutečný GIANTS ObjectStorage inventář;
plně autonomní VYSKLADNĚNÍ + přistavení + naložení balíků dosud není
ověřené, balíky nesmí být virtuálně přeneseny. Fyzický výsypný
trigger chovu nemusí být zároveň podporovaným GIANTS AIJobDeliver cílem.

POZOR: 0.20.35.0 není otestovaná přímo ve hře FS25. Vhodné testovat na
kopii savegame. Alt+D opět vytvoří jeden souhrnný diagnostický report.

FARM MANAGER AI 0.20.34.0 — OPRAVA DLE REÁLNÉHO HERNÍHO TESTU

Vydání navazuje na 0.20.33.0 a na FS25 log ze dne 3. října 2026.
Courseplay hutnění používá skutečný registrovaný job vozidla, veřejný CP
start, skutečnou počáteční polohu traktoru a střed geometrie bunkru.
U blízkých vjezdů předchází zbytečnému GoTo na odvozený bod za stěnou.
Nepřebírá jiné běžící pracovníky. Auto výběr úloh je nově výchozí.
Pro vlastní zahájení manageru je i nadále potřeba Alt+H.

Vývojový balík: 531 offline testů úspěšných. Chování ve skutečném FS25
teprve ověř na kopii uložené farmy. Kompletní popis:
docs/OPRAVA_Z_HERNIHO_TESTU_02034_CZ.md

FARM MANAGER AI 0.20.33.0 — JEDEN DIAGNOSTICKÝ SOUBOR + BEZPEČNÝ TEST

NOVÁ HLAVNÍ FUNKCE: Po Alt+D najdeš na Ploše jediný soubor,
FS25_FarmManagerAI_REPORT.txt. Ten mi stačí jako první podklad k řešení chyb.

V reportu: diagnostika celé farmy, aktuální stav LIVE, provozní zprávy,
posledních 12 úseků TRACE uložených v paměti právě běžící relace,
a pasivní kontrola dostupných strojů, budov, zakázek a Courseplay.

ALT+M -> CO CHYBÍ -> DIAGNOSTICKÝ TEST + JEDEN REPORT spustí
stejný export po bezpečné kontrole bez pohybu techniky.

Nečekej až po ukončení FS25: Alt+D proved ještě ve hře,
protože starší TRACE úseky po restartu nelze znovu přečíst
z chráněných souborů v herním prostředí.

OMEZENÍ: Původní GIANTS log.txt ani interní debug výpisy Courseplay
nemohou být za všech okolností přidány do reportu přes FS25 Lua.
Při chybě, kterou manager nemůže zachytit, může být potřeba
poslat i FarmingSimulator2025/log.txt — to je ale výjimka.

Nainstaluj ZIP do mods, testuj zálohovanou kopii farmy.
Vývojová verze — samotné offline testy neprokazují fyzickou funkčnost.
Kompletní návod: docs/JEDEN_DIAGNOSTICKY_SOUBOR_02032_CZ.md.

FARM MANAGER AI 0.20.30.0 — KURZOR, SILÁŽNÍ JÁMY A PÉČE O CHOVY

Nainstaluj ZIP do mods (ne do savegame). Zachovej kopii původního savegame.

NOVINKA: FMAParkingManager – klasifikace vlastních budov a typů nářadí;
    naučená parkovací stání podle role, fyzické rozměry, rezervace, obsazenost;
    výběr stání po práci, postupné uspořádání volných motorových strojů.

Alt+M -> MAPA:
- NAUČIT STÁNÍ STROJE (z bezpečné zaparkované polohy)
- NAUČIT STÁNÍ NÁŘADÍ (s připojeným nářadím)
- USPOŘÁDAT VOLNÉ STROJE (vyžaduje zapnutou automatiku)
- SMAZAT POSLEDNÍ STÁNÍ

UPOZORNĚNÍ: Neznámá vrata/kolize garáže nejsou automaticky vyřešené.
Na silně rozházené farmě musíš naučit několik bezpečných parkovacích míst.
Samovolný přesun už odpojeného nářadí bez fyzického zapřažení neprobíhá.
Základní část dopravních a pracovních mechanismů není ve hře nezávisle ověřená.

Podrobný postup: docs/PARKOVANI_02029_CZ.md.
Stará dokumentace a projektní specifikace zůstávají součástí ZIPu.

AKTUALIZACE 0.20.30.0:
- Alt+M obnovuje kameru a uvolňuje vlastní kurzor, i když ostatní mody užívají vlastní HUD.
- Naplněné nezhutněné silážní jámy vytvářejí samostatné zakázky i bez nové dodávky.
- Zjištěná potřeba slámy, vody a krmiva ve stájích vytváří zakázku. Když existuje ověřený AI zdroj a cíl, je zásobování navázáno na skutečnou přepravu; jinak je zakázka BLOCKED s důvodem.
- START pouze schválených zakázek. Falešné splnění nebo jízda do středu budovy není povolena.
- Viz docs/OPRAVA_KURZOR_SILAZ_CHOV_02030_CZ.md.
- NEOVĚŘENO VE HŘE: skutečné řízení všech jam, nakládka balíků, fyzický odvoz vody a plně autonomní chov.
