# 모아봄

링크만 넣으면 영상·사진을 내 서버(NAS)에 받아 두고, 아이폰·아이패드에서 편하게 모아 보는 개인용 클립 보관함입니다.

- **받기**: X(트위터) 게시물 링크(사진 여러 장 + 영상), 그 밖에 yt-dlp가 지원하는 사이트
- **자동 감시**: 지정한 X 계정의 새 게시물, 내 좋아요를 주기적으로 받아 둠
- **분류**: 3단계 분류(이름은 직접 정함). 분류를 바꾸면 서버의 실제 폴더도 함께 옮겨져서, 앱 없이 파일 탐색기로 봐도 정리된 상태가 유지됨
- **보기**: 보관함 그리드, 세로로 넘기는 둘러보기, 즐겨찾기
- **앱**: SwiftUI iOS/iPadOS 앱 (`ios/`) — 오프라인 우선 동기화, 캐시 용량 제한, Face ID 잠금, 공유 시트로 받기

## 구조

```
server/            FastAPI 서버 + 웹 UI
  app/
    main.py        앱 조립, 웹소켓
    config.py      환경변수 설정 (비밀값은 전부 .env)
    db.py          SQLite 스키마/마이그레이션
    auth.py        웹 세션 쿠키, 앱 토큰, 로그인 시도 제한
    library.py     미디어 색인(파일 ↔ DB), 분류 변경 시 파일 이동, 썸네일, 메타데이터
    dlqueue.py     다운로드 대기열
    downloader.py  gallery-dl / yt-dlp 실행
    watcher.py     X 계정·좋아요 감시
    routes/        API
    static/        웹 UI
  tests/           pytest
ios/               iOS 앱
docker-compose.yml
.env.example
```

## 서버 실행

```bash
cp .env.example .env      # MOABOM_USER / MOABOM_PASS 등 입력
docker compose up -d --build
```

- 보관 폴더: `MOABOM_LIBRARY_HOST` (컨테이너 안 `/downloads`)
- DB·쿠키·썸네일 캐시: `./data`
- TLS: `MOABOM_CERT_DIR`에 인증서를 두면 HTTPS로 뜸 (`MOABOM_TLS_KEY`, `MOABOM_TLS_CERT`로 파일 이름 지정)

처음 실행하면 보관 폴더를 읽어 색인을 만듭니다. 이미 있는 폴더 구조(`분류1/분류2/분류3/파일`)는 그대로 분류로 들어오고, 이후 설정 → 분류 관리에서 이름 변경/합치기/삭제/순서 변경을 할 수 있습니다.

### 폴더 규칙

| 상태 | 폴더 |
|---|---|
| 분류됨 | `<분류1>/<분류2>/<분류3>/` (뒤쪽 빈 단계는 생략, 중간이 비면 `미분류`) |
| 감시 계정에서 받음 (미분류) | `자동감시/@계정/` |
| 좋아요에서 받음 (미분류) | `좋아요/` |
| 직접 받음 (미분류) | `미분류/` |

## API 요약

인증: 웹은 쿠키, 앱은 `Authorization: Bearer <토큰>` (`POST /api/auth/login` `{client:"app"}`로 발급). 미디어 파일은 `?token=`도 허용.

| | |
|---|---|
| `GET /api/sync?since=<rev>` | 변경분 동기화 (미디어·분류, 삭제는 `deleted=1`) |
| `GET /api/media` | 목록 (필터 `c1..c3`(`none`=미분류), `source`, `kind`, `favorite`, `sort=new/old/random`) |
| `GET /api/media/{id}/file` | 원본 (Range 지원) |
| `GET /api/media/{id}/thumb?w=240/480/960` | 썸네일 |
| `POST /api/media/classify` | `{ids, c1?, c2?, c3?}` 보낸 단계만 변경, `null`=미분류. 응답의 `undo`로 되돌리기 |
| `POST /api/media/undo` · `/delete` · `/favorite` | |
| `GET/POST/PATCH/DELETE /api/categories…` | 분류 관리 (이름 변경·합치기·삭제는 파일도 이동) |
| `POST /api/download` | `{url, c1?, c2?, c3?}` |
| `GET /api/downloads`, `/api/watch`, `/api/stats` | |
| `WS /ws` | 진행률·변경 알림 |

## 개발

```bash
cd server
python -m venv .venv && . .venv/bin/activate
pip install -r requirements.txt pytest pytest-asyncio
pytest           # ffmpeg 필요
```

## 라이선스

MIT
