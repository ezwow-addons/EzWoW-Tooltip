# v2.0.30

### 한국어
- "상점 판매가" 줄의 개수(×N)가 가진 전체 개수로 나와, 링크·전리품이나 겹치지 않는 장비에도 줄이 하나 더 붙던 문제를 고쳤습니다. 이제 마우스 아래 묶음의 개수를 씁니다.
- EzWoW 가방에서도 묶음에 마우스를 올리면 상점 판매가·구입가가 묶음 개수(×N)로 나옵니다.
- 애드온에 든 데이터가 다 있으면 공용 데이터 애드온의 데이터를 불러오지 않아 메모리를 덜 씁니다.
- 공유 기록 저장 데이터가 오래 쓰면 조금씩 커지던 문제를 고쳤습니다.

### English
- Fixed the vendor sell price line counting every copy you own (×N), which added an extra line to links, loot and non-stacking gear. It now uses the stack under the mouse.
- Stacks in EzWoW bags now show the vendor sell and buy prices for the whole stack (×N).
- Uses less memory: the shared data addon's modules are no longer loaded when the addon's own data is complete.
- Fixed shared-record save data slowly growing over long use.
