# FS25 FarmManagerAI — sjednocené zadání a přejímka skutečné autonomie
**Základ: uživatelské konverzace o automatizaci FS25, zejména „Dokončit Farm Manager autonomně“ (3.–4. 10. 2026).**
**Cílové prostředí:** Farming Simulator 25 1.15.0.0 · mapa Karpatský venkov · aktuální Courseplay · další obsah z oficiálního ModHubu.
**Stav k 4. 10. 2026:** vývojový mod. Offline testy jsou pouze pojistkou; plně samostatný provoz ve skutečné hře dosud nebyl prokázán.

## Neměnné zásady
- Hráč je předseda / dispečer družstva. Po aktivaci AUTO má systém **sám** vyhledat potřeby farmy, určit prioritu, zvolit dostupnou vhodnou techniku, fyzicky sestavit soupravu, dopravit ji na místo, vykonat práci, přemístit materiál a vrátit stroje do reálných stání.
- Žádné falešné úspěchy: spuštěný příkaz, stav `running`, naplánovaná trasa ani zvýšený počet testů **nejsou** důkaz splněného úkolu.
- Bez teleportování, přesouvání plodin a balíků změnou čísla, průjezdu přes neznámé zdi / brány nebo virtuálního zapřažení.
- Žádné opakované restartování zaseklých AI úloh bez zjištění příčiny. Omezené pokusy, jiný průjezd / stroj jen při nové fyzicky doložené skutečnosti. Bezpečně zablokovat a sdělit konkrétní důvod, pokud nelze pokračovat.
- Zachovat existující Lua moduly, jejich odpovědnosti a průběžně ověřovat regresní testy; cílené opravy namísto přepisování základů.
- Originální savegame nesmí být pokusným provozem ohrožen. Testy v herním enginu jen na kopii. Nepřebírat hráčovo řízení ani cizí Courseplay/GIANTS práci proti vůli hráče.
- Distribuovat **výhradně** `FS25_FarmManagerAI.zip` (žádná verze, závorky ani datum v názvu); verze se uvádí pouze uvnitř modu. ZIP vkládat do `mods` bez rozbalování.

## Funkční rozsah — jedna navazující pracovní zakázka
| Oblast | Co musí fyzicky fungovat | Co se nesmí považovat za dokončení |
| --- | --- | --- |
| Dispečink | Průzkum všech vlastních polí, strojů, budov, chovů, jam, zásob a cen; závislosti a priority úloh | Pouhý záznam zakázky v tabulce |
| Stroje | Vybrat odpovídající výkon, připojit správné nářadí, manipulovat adaptérem na přepravníku, nastartovat a dojet | Zvolený pár stroj+nástroj bez fyzického závěsu |
| Silnice | Reálná cesta po mapě, ověřený nájezd ze dvora, ověřený výjezd k poli a návrat; šířky souprav a kolize | GIANTS/CP „start accepted“ bez pohybu a bez přiblížení |
| Pole | Orba, příprava, vápnění, postřik, hnojení, setí, válení, sklizeň a následné operace v agronomickém pořadí | Start Courseplay bez změny stavu pole |
| Sklizeň | Samostatná četa kombajn + adaptéry + 1–2 odvozci, podpora při cca 80 % a podle predikce, překládka a odvoz | Fiktivní vysypání nebo souběžné přidělení jednoho odvozce |
| Pícniny a sláma | Seč, obracení, shrnování, lisování, sběr řádků v jejich středu, odvoz balíků a fyzické uskladnění | Změna inventáře bez zvednutí a přepravy balíku |
| Siláž | Naskladnění do správné jámy, koordinace dopravy a hutnění více traktory bez kolize, střídavé průjezdy dopředu/dozadu | Požadavek na CP kompakci bez pohybu nebo bez nárůstu zhutnění |
| Zvířata | Voda, sláma, krmivo / skutečná TMR receptura a výroba, odvoz mléka, hnůj, kejda, upozornění na chybějící vstupy | Nakreslená úloha při chybějícím kompatibilním plnicím/výsypném bodu |
| Logistika | Fyzický přesun sklizené produkce, doplnění nafty/semen/hnojiv, sklady, transport k prodeji; nákup chybějících surovin dle pravidel | Teleport do skladu nebo automatický neodsouhlasený nákup vozidel |
| Návrat | Po skutečné práci odpojit a bezpečně zaparkovat vozidlo, nářadí, přepravník a adaptér na známá stání | Ukončení zakázky bez potvrzeného stání |

## UI a ovládání — nesmí zasahovat do hry
- `Alt+M` konzole; `Alt+H` zapnutí/vypnutí AUTO; `Alt+D` okamžitý export jediného souhrnného reportu `FS25_FarmManagerAI_REPORT.txt`.
- `Enter` hráči startuje motor — beze změny; `E` pro nástup do stroje — beze změny; `ESC` originální FS25 menu; `Alt+P` neobsazovat (konflikt s úpravou profilu).
- Myš a její kurzor musí být získány pouze při opravdu otevřené konzoli; po jejím zavření normální nekonečné otáčení kamery / ovládání hry.
- Čitelná samostatná konzole s přehledem, polem, sklizní, siláží, zvířaty, stroji, problémy, mapou a diagnostikou. Nezakrývat FS25/CP nabídky ani se nepřipojovat na GIANTS ESC menu.

## Přísný proces ověřování
1. **Offline:** Lua syntax, statické brány, jednotkové/kontraktové testy, integrita ZIP. Evidence: GitHub Actions výsledek a build artifact. To prokazuje jen vnitřní konzistenci.
2. **Ve hře:** jedno společné přejímací prostředí na **kopii** farmy Karpatský venkov, stejná sada ModHub modů, Courseplay, stejný savegame. Zachovat přirozené chování Enter/E/H/ESC/kamery.
3. **Scénář A – zapřažení a odjezd:** 6R 250 + 9620 Air Boom Applicator: odvodit skutečné dva závěsy, dojet, potvrdit `getAttachedImplements`, odjet k poli. Starší TRACE uvádělo chybnou vzdálenost 5,62–7,18 m.
4. **Scénář B – LEXION:** LEXION 6900 s vhodnou lištou/přepravníkem fyzicky vyjede, dojede ke konkrétnímu poli (přejímací pole 64), Courseplay **skutečně** sklízí a stav úrody se mění. „Spuštěno“ bez pohybu je neúspěch.
5. **Scénář C – jáma:** 6R/9R/XERION bezpečně fyzicky projíždějí správným směrem, neperou se o jeden koridor, nepřebírají navzájem řízení, procento zhutnění roste. Při překážce zastavit, nikoli projet zdí.
6. **Scénář D – logistika:** naložení → měřitelný úbytek skutečného zdroje → měřitelný přírůstek cíle → dokončení a návrat. Totéž pro slámu/balíky/krmiva podle podpory fyzikálních triggerů.
7. **Scénář E – návrat:** skutečná cesta domů a potvrzené parkování / odpojení, bez zabrání hráčova vozidla.
8. **Scénář F – regresní ovládání:** otevřít/zavřít `Alt+M` a ověřit volnou kameru, E, Enter, ESC a Courseplay; žádné problémy se save.
9. **Důkazní měření:** poloha a fyzické ujeté metry, job ownership, motor, skutečná práce na poli/jámě, množství převáženého materiálu, závěsy, kolize, návrat. Jeden report Alt+D; běžný `log.txt` jen když report nezachytí engine chybu.

## Další požadavky z návrhu reálného JZD — backlog, ne hotové funkce
- Směny, kvalifikace, únava pracovníků a předávání práce mezi osádkami; žádný virtuální pracovník nesmí obejít fyziku vozidla ani GIANTS/CP.
- Před zahájením zakázky kontrola stavu stroje, servis, vhodnost agregace a výkonu, správné náplně a skutečná hmotnost/naložení tam, kde je hra umí zjistit.
- Celý řetězec v delší perspektivě: **kontrola → sestavení → doplnění/vážení → přejezd → práce → kontrola výsledku → odvoz → návrat → vyčištění a odstavení**.
- Pracovní návaznosti živočišné, rostlinné i výrobní části; mlékárna, kejda, hnůj, siláž, plodiny, skladové vstupy/výstupy a obsluha výrob.
- Přehled nákladů, možnost ekonomicky doporučit nový stroj, logika prodeje a doplňování zásob; nenakupovat drahou techniku automaticky bez jasného pověření.
- Krizové situace: poškozený/stojící stroj, neprůjezdný objekt, nedostatek paliva, ucpaný koridor, nefunkční trigger, vypnutý Courseplay. Náhradní postup smí běžet jen po ověření reálného stavu.
- Živé mapování skutečné mapy a postupné učení bezpečných projetých cest (i alternativních), ale **bez úpravy** původních cest nebo budov Karpatského venkova. Přidané silážní jámy, sila a prodejní místa musí být zjištěny živým skenem.
- Správa hráčem řízeného traktoru jako člena čety; hráč může občas řídit sám a pak předat řízení zpět. Automatika nemění jeho E, Enter ani kameru.
- Robustní menu podobně přehledné jako Courseplay, ovladatelné myší i klávesnicí; v konzoli jasně vidět aktivní zaměstnance, vytíženost, chybějící stroje, možnosti nákupu, úkoly a problémy.

**Stav:** Výše uvedené jsou dlouhodobé požadavky. Přítomnost názvu modulu v ZIPu není důkaz, že je některý z těchto pracovních procesů dokončen. Každý se musí samostatně přijmout fyzickým testem.

## Pořadí další práce
- **P0 – provozní kontinuita:** přijetí a potvrzení AI startu → reálný odjezd → bezpečný segmentovaný přejezd → skutečné fyzické vykonání → uvolnění řízení → bezpečný návrat. Dlouhá cesta nesmí být nahrazena fiktivním zkratem.
- **P1 – konkrétní zaseklé stroje:** 6R 250/9620 připojení; LEXION 6900 v poli 64; XERION/6R/9R v silážní jámě. Opravu každého případu musí potvrdit nový in-game report, nejen nový test.
- **P2 – kompletní zemědělské řetězce:** materiál, chovy, lisování, balíky, obchod, nákupy, AI logistika, parkování.
- **P3 – příjemný provoz:** robustní UI, srozumitelné upozornění, méně ručních zásahů, automatická diagnostika; bez agresivního přebírání ovládání.

**Přejímka neprojde, pokud některý kritický scénář pouze „nehlásí chybu“. Musí existovat konkrétní fyzický důkaz.**
