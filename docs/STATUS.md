# Stav projektu – věcná kritéria dokončení

Tato verze **NENÍ** plně funkční autonomní farma. Na skutečném FS25 dosud nejsou potvrzené celé pracovní cykly.

## Skutečně ověřeno

- syntaktická kontrola Lua skriptů a 607 offline logických/kontraktových testů (Lua 5.4, nikoli GIANTS runtime)
- plánování dlouhé silniční trasy po skutečných spline objektech (syntetický graf)
- omezené nájezdy ze dvora a výjezdy z veřejné silnice; všechny dílčí úseky podléhají FS25 fyzickému potvrzení
- balení reprodukovatelného ZIPu a zkouška struktury archivu

## Dosud NEověřeno v reálné hře

1. LEXION s připojeným adaptérem skutečně přijede k poli 64 a začne sklízet.
2. Traktor zapřáhne správné nářadí z volného odstavného místa a odjede na pole bez kolize.
3. 6R a 9R provádějí bezpečné průjezdy sem a tam při hutnění, ne pouze GIANTS příkaz.
4. Odvoz a logistika skutečně přemisťují objem materiálu.
5. Stroj se po práci vrátí na ověřené parkovací místo bez falešného dokončení.

Rozhodující důkaz: fyzický pohyb, změna stavu pole/sila, dokončení úkolu a bezpečný návrat. Žádné počítadlo offline testů není náhrada.

Když test selže, stačí export **Alt+D → FS25_FarmManagerAI_REPORT.txt**. Hlavní savegame zálohuj a vývojové sestavení zkoušej výhradně na kopii.
