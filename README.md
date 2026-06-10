# AgentPulse

macOS 메뉴바 상주 앱. Claude Code·Codex·Hermes 세 AI 코딩/에이전트 툴이
**어떤 MCP 서버와 Skill을 얼마나 썼는지** 주간·월간·기간지정 그래프로 보여준다.

순수 Swift (SwiftUI `MenuBarExtra` + Swift Charts). 외부 의존성 없음.

## 다운로드

[**AgentPulse.dmg 직접 다운로드 (v1.12.0)**](https://github.com/beyondworks/agentpulse/releases/download/v1.12.0/AgentPulse.dmg) — 열어서 AgentPulse를 Applications로 드래그.
전체 릴리스: [Releases](https://github.com/beyondworks/agentpulse/releases).

> **플랜 잔량 라이브 표시 요건**: 한 번이라도 `claude /login`(CLI 로그인)을 해야 키체인에 토큰이 생겨 표시됩니다(데스크톱앱 전용 사용자는 표시 안 됨). 첫 실행 시 macOS 키체인 접근 프롬프트에서 **"항상 허용"**을 누르세요.

## 빌드 & 실행

```bash
# 1) 수집기 검증 (헤드리스) — 로그를 파싱해 usage.db를 채우고 30일 리포트 출력
swift run agentpulse-cli

# 2) 메뉴바 앱 빌드 (.app 번들)
./scripts/make_app.sh
open AgentPulse.app          # 메뉴바 우측에 막대그래프 아이콘 등장

# 3) DMG로 패키징 (드래그-투-Applications 설치)
./scripts/make_dmg.sh        # AgentPulse.dmg 생성
```

로그인 시 자동 실행은 앱 하단 체크박스(또는 `SMAppService`)로 토글한다.
`.app`을 `/Applications`로 옮긴 뒤 켜면 안정적이다.

### DMG 설치

`AgentPulse.dmg`를 열고 AgentPulse를 Applications로 드래그한다.

> 이 앱은 **ad-hoc 서명(미공증)**이다. **빌드한 본인 맥에선** 경고 없이 실행된다.
> **다른 맥에서 내려받으면** 첫 실행 때 Gatekeeper 경고가 한 번 뜬다 →
> 앱을 **우클릭 → 열기**(1회) 하거나:
> ```bash
> xattr -dr com.apple.quarantine /Applications/AgentPulse.app
> ```
> 경고 자체가 없는 배포는 Apple Developer ID + notarization이 필요하다.

### 디버그 모드
```bash
.build/debug/AgentPulse --render out.png [mcp|skill|tool]   # SwiftUI 뷰만 PNG로 (차트 확인)
.build/debug/AgentPulse --snap   out.png [mcp|skill|tool]   # 네이티브 컨트롤 포함 실제 뷰 캡처
agentpulse-cli --report                                     # 수집 없이 캐시 리포트만
```

## 라이브 모니터링 (v1.1)

상단 라이브 섹션에서 실시간 상태를 본다.

- **플랜 사용량** — Claude Max 구독의 `5시간 / 주간 / Sonnet 주간` 사용 %. 출처는 OMC HUD가
  `api.anthropic.com/api/oauth/usage`를 받아 캐시한 `~/.claude/plugins/oh-my-claudecode/.usage-cache.json`
  (AgentPulse는 이 파일만 읽음 — 자격증명·네트워크 접근 없음). 구독(OAuth) 세션에서만 의미가 있고,
  API-key 세션에선 한도 개념이 없어 "오래됨/정보 없음"으로 정직하게 표기.
- **컨텍스트 80% 압축 권고 푸시** — 작업중인 Claude Code 세션의 컨텍스트창 점유율을 추적해, 임계치
  (기본 80%, 슬라이더 조절) 도달 시 **macOS 알림**(`/compact 권장`). 25초 주기 폴.
  - 점유율 = 활성 트랜스크립트 마지막 `usage`의 `input+cache_read+cache_creation` ÷ 컨텍스트 창 크기.
    창 크기(200k/1M)는 세션 statusLine 캐시(`~/.claude/hud/cache/stdin.<id>.json`)에서 가져온다.
  - **세션별 독립**: 세션마다 상태(armed/disarmed)를 들고, used%는 각 세션 창 기준이라 병렬 작업도 정확.
    알림 identifier = `ctx-<sessionId>`(중복 누적 대신 갱신). 압축으로 % 떨어지면 재무장, 세션당 재알림 10분 간격.
  - **병렬 동시 도달**: 세션마다 프로젝트 라벨로 구분된 별도 알림. 한 번에 3개 초과면 요약 1건으로 합침.
  - 알림은 UNUserNotificationCenter(번들 실행) → 권한 미허용/비번들 시 `osascript`로 자동 전환.

## 구조

```
Collector(증분 파싱) → usage.db(일별 집계 캐시) → MenuBarExtra UI(Swift Charts)
```

- **Collector** — 3개 소스를 증분 파싱. JSONL은 (mtime, byte-offset), Hermes DB는 last-rowid로
  변경분만 읽는다. 첫 풀스캔 ~90초, 이후 재실행 ~0.3초.
- **usage.db** (`~/Library/Application Support/AgentPulse/usage.db`) — `usage(tool,category,item,day,profile,count)`
  일별 버킷. 주간/월간/기간 = day 범위 합산. 원본은 읽기 전용으로만 접근.
- **UI** — 기간(주간·월간·기간지정) × 툴(전체·Claude·Codex·Hermes) × 카테고리(MCP·Skill·Tools)
  필터 + 추세/Top 차트 + 랭킹 리스트. 앱 시작 + 10분 주기로 백그라운드 증분 수집.

## 데이터 소스 (직접 검증)

| 툴 | 경로 | MCP | Skill | Tools |
|----|------|-----|-------|-------|
| Claude Code | `~/.claude/projects/**/*.jsonl` | `mcp__server__tool` | `Skill` tool의 `input.skill` | 내장 도구(Read/Bash…) |
| Codex | `~/.codex/sessions/**/rollout-*.jsonl` | `mcp__` 접두 호출만 | — | `function_call`/`custom_tool_call` |
| Hermes | `~/.hermes/profiles/{persona}/state.db` | — | `skill_view`의 `arguments.name` | `tool_calls[].function.name` |

각 툴은 서로 다른 네임스페이스를 가진다. MCP는 Claude Code·Codex만, Skill은 Claude Code·Hermes만
의미가 있다(보여줄 데이터가 없으면 0으로 표시).

## 알려진 한계

- **Codex MCP** — Codex가 대부분의 MCP 도구명을 평탄화(prefix 제거)해서 노출하므로, 깔끔한
  `mcp__server__tool` 형태만 MCP로 귀속한다. 나머지는 Tools에 집계된다.
- **Hermes 정본** — persona별 `state.db`만 사용한다. 구 `~/.hermes/state.db`(5월 중순까지)와
  web-ui DB는 부분 데이터라 제외.
- **UUID MCP 서버** — 커넥터 UUID 서버는 `93138da9…`처럼 축약 표기한다.
- 시크릿 보호: 도구명·skill명·타임스탬프만 추출하며 메시지 본문/인자값은 저장·표시하지 않는다.

## 정확성 검증

- Claude `playwright` MCP: 캐시 151 = `grep` 원본 151 (정확 일치)
- Hermes skill: 캐시 2673 = persona DB 원본 재집계 2673 (정확 일치)
- 증분 재실행 시 중복 집계 없음(2회 실행 후에도 동일 카운트)
