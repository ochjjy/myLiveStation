#!/usr/bin/env bash
# check_streams.sh — 라디오 스트림 상태 점검 스크립트
#
# 사용법:
#   ./check_streams.sh              # 기본 실행 (컬러 출력 + 로그 저장)
#   ./check_streams.sh --quiet      # 실패한 항목만 출력 (크론 권장)
#   ./check_streams.sh --no-log     # 로그 파일 저장 안 함
#   ./check_streams.sh --parallel   # 병렬 실행 (빠르지만 출력 순서 불규칙)
#
# 크론 등록 예시 (6시간마다):
#   0 */6 * * * /path/to/check_streams.sh --quiet >> /path/to/stream_checks.log 2>&1
#
# 판정 기준:
#   - curl exit 63 (max-filesize 도달)  → OK  (오디오 데이터 수신 확인)
#   - curl exit  0 + HTTP 200 + bytes>0 → OK  (일반 HTTP 스트림)
#   - exit 6  = DNS 실패
#   - exit 28 = 타임아웃
#   - exit 35/60 = SSL 오류
#   - 그 외  = FAIL

set -euo pipefail

# ── 설정 ──────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JSON_FILE="${SCRIPT_DIR}/streams.json"
LOG_FILE="${SCRIPT_DIR}/stream_checks.log"
CONNECT_TIMEOUT=8
MAX_TIME=12
MAX_FILESIZE=65536   # 64 KB

# ── 옵션 파싱 ─────────────────────────────────────────────────────────────
QUIET=false
NO_LOG=false
PARALLEL=false
for arg in "$@"; do
  case "$arg" in
    --quiet)    QUIET=true ;;
    --no-log)   NO_LOG=true ;;
    --parallel) PARALLEL=true ;;
    --help|-h)
      sed -n '2,20p' "$0" | sed 's/^# //' | sed 's/^#//'
      exit 0 ;;
  esac
done

# ── 컬러 (tty 아닐 때 비활성) ─────────────────────────────────────────────
if [ -t 1 ]; then
  GRN='\033[0;32m'; RED='\033[0;31m'; YLW='\033[0;33m'
  BLU='\033[0;34m'; DIM='\033[2m';    RST='\033[0m'
else
  GRN=''; RED=''; YLW=''; BLU=''; DIM=''; RST=''
fi

# ── 스트림 데이터 (streams.json 없을 때 내장 fallback) ────────────────────
# ID|이름|URL
declare -a STREAMS_DATA=(
  "bbc3|BBC Radio 3|http://as-hls-ww-live.akamaized.net/pool_23461179/live/ww/bbc_radio_three/bbc_radio_three.isml/bbc_radio_three-audio=320000.norewind.m3u8"
  "france-musique|France Musique|https://stream.radiofrance.fr/francemusique/francemusique.m3u8"
  "rsc-mp3|Radio Swiss Classic (MP3)|https://stream.srg-ssr.ch/m/rsc_de/mp3_128"
  "rsc-aac|Radio Swiss Classic (AAC)|https://stream.srg-ssr.ch/m/rsc_de/aacp_96"
  "nrk-klassisk|NRK Klassisk|https://lyd.nrk.no/nrk_radio_klassisk_mp3_h"
  "hotmix-kpop|Hotmix K-Pop|https://streaming.hotmixradio.com/hotmix-k-pop-en-mp3"
  "rtl-kpop|RTL Berlin K-Pop|https://rtlberlin.streamabc.net/rtlb-kpop-mp3-128-8737982"
  "excl-kpop|Exclusive Radio K-Pop|http://streaming.exclusive.radio/er/kpop/icecast.audio"
  "tsf|TSF Jazz|https://tsfjazz.ice.infomaniak.ch/tsfjazz-high.mp3"
  "rsj-mp3|Radio Swiss Jazz (MP3)|https://stream.srg-ssr.ch/m/rsj/mp3_128"
  "rsj-aac|Radio Swiss Jazz (AAC)|https://stream.srg-ssr.ch/m/rsj/aacp_96"
  "nrk-jazz|NRK Jazz|https://lyd.nrk.no/nrk_radio_jazz_mp3_h"
  "fip|FIP Radio|http://icecast.radiofrance.fr/fip-lofi.mp3"
  "rsp-mp3|Radio Swiss Pop (MP3)|https://stream.srg-ssr.ch/m/rsp/mp3_128"
  "rsp-aac|Radio Swiss Pop (AAC)|https://stream.srg-ssr.ch/m/rsp/aacp_96"
  "france-inter|France Inter|http://icecast.radiofrance.fr/franceinter-lofi.mp3"
  "antenne-bayern|Antenne Bayern|http://stream.antenne.de/antenne/stream/mp3"
  "antenne-love|Antenne Bayern Love Songs|http://stream.antenne.de/lovesongs/stream/mp3"
  "181-heart|181.FM – The Heart|https://listen.181fm.com/181-heart_128k.mp3"
  "181-lite90s|181.FM – Lite 90s|https://listen.181fm.com/181-lite90s_128k.mp3"
  "181-mellow|181.FM – Mellow Gold|https://listen.181fm.com/181-mellow_128k.mp3"
  "capital-fm|Capital FM|https://media-ice.musicradio.com/CapitalMP3"
  "calm-easy|Calm Radio Easy Listening|http://streams.calmradio.com/api/1012/128/stream"
  "npr|NPR News|https://npr-ice.streamguys1.com/live.mp3"
  "rfi|RFI World|http://live02.rfi.fr/rfimonde-64.mp3"
  "france-info|France Info|http://icecast.radiofrance.fr/franceinfo-lofi.mp3"
)

# ── jq로 streams.json 읽기 (있을 경우 우선) ──────────────────────────────
load_from_json() {
  if ! command -v jq &>/dev/null; then return 1; fi
  if [ ! -f "$JSON_FILE" ]; then return 1; fi
  STREAMS_DATA=()
  while IFS= read -r line; do
    STREAMS_DATA+=("$line")
  done < <(jq -r '.streams[] | "\(.id)|\(.name)|\(.url)"' "$JSON_FILE")
  return 0
}

# ── 단일 스트림 점검 ──────────────────────────────────────────────────────
check_stream() {
  local id="$1" name="$2" url="$3"
  local tmp_out exit_c http_code bytes_recv detail

  tmp_out=$(mktemp 2>/dev/null || echo "/tmp/sc_$$_${id}")

  # set -e 환경에서 curl 비정상 exit(63 등)에 스크립트가 종료되지 않도록
  # || true 없이 exit code를 정확히 캡처
  set +e
  http_code=$(curl -sS -L \
    --connect-timeout "$CONNECT_TIMEOUT" \
    --max-time "$MAX_TIME" \
    --max-filesize "$MAX_FILESIZE" \
    -H "User-Agent: WinampMPEG/5.0" \
    -H "Icy-MetaData: 1" \
    -o "$tmp_out" \
    -w "%{http_code}" \
    "$url" 2>/dev/null)
  exit_c=$?
  set -e

  # macOS: stat -f%z / Linux: stat -c%s
  bytes_recv=$(stat -f%z "$tmp_out" 2>/dev/null \
    || stat -c%s "$tmp_out" 2>/dev/null \
    || wc -c < "$tmp_out" | tr -d ' ') 2>/dev/null || bytes_recv=0
  rm -f "$tmp_out"

  if [ "$exit_c" -eq 63 ]; then
    detail="OK (스트리밍 데이터 수신, ${bytes_recv}B)"
    echo "OK|$detail"
    return 0
  fi

  if [ "$exit_c" -eq 0 ] && [ "$http_code" = "200" ] && [ "${bytes_recv:-0}" -gt 512 ]; then
    detail="OK (HTTP 200, ${bytes_recv}B)"
    echo "OK|$detail"
    return 0
  fi

  # HLS m3u8 플레이리스트: 200 + 소량 텍스트도 OK로 간주
  if [ "$exit_c" -eq 0 ] && [ "$http_code" = "200" ] && [ "${bytes_recv:-0}" -gt 0 ]; then
    case "$url" in
      *.m3u8*|*.isml*)
        detail="OK (HLS 플레이리스트, ${bytes_recv}B)"
        echo "OK|$detail"
        return 0 ;;
    esac
  fi

  case "$exit_c" in
    6)   detail="FAIL (DNS 해석 실패)" ;;
    7)   detail="FAIL (연결 거부)" ;;
    28)  detail="FAIL (타임아웃 ${MAX_TIME}s)" ;;
    35)  detail="FAIL (SSL 핸드셰이크 오류)" ;;
    60)  detail="FAIL (SSL 인증서 오류)" ;;
    56)  detail="FAIL (수신 오류 exit56, HTTP ${http_code})" ;;
    22)  detail="FAIL (HTTP ${http_code})" ;;
    0)   detail="FAIL (HTTP ${http_code}, ${bytes_recv}B)" ;;
    *)   detail="FAIL (curl exit ${exit_c}, HTTP ${http_code})" ;;
  esac
  echo "FAIL|$detail"
  return 1
}

# ── 단일 스트림 출력 ──────────────────────────────────────────────────────
print_result() {
  local id="$1" name="$2" status="$3" detail="$4"
  local padded_id padded_name

  printf -v padded_id   '%-18s' "$id"
  printf -v padded_name '%-30s' "$name"

  if [ "$status" = "OK" ]; then
    if ! $QUIET; then
      printf "${GRN}✓${RST}  ${DIM}%-18s${RST}  %-30s  ${GRN}%s${RST}\n" \
        "$id" "$name" "$detail"
    fi
  else
    printf "${RED}✗${RST}  ${DIM}%-18s${RST}  %-30s  ${RED}%s${RST}\n" \
      "$id" "$name" "$detail"
  fi
}

# ── 로그 라인 (컬러 없이) ─────────────────────────────────────────────────
log_result() {
  local ts="$1" id="$2" name="$3" status="$4" detail="$5"
  printf '[%s]  %-5s  %-18s  %-30s  %s\n' \
    "$ts" "$status" "$id" "$name" "$detail" >> "$LOG_FILE"
}

# ── 메인 ──────────────────────────────────────────────────────────────────
main() {
  load_from_json || true  # 실패해도 내장 fallback 사용

  local total=${#STREAMS_DATA[@]}
  local ok_count=0 fail_count=0
  local ts; ts=$(date '+%Y-%m-%d %H:%M:%S')
  local failed_list=()

  if ! $QUIET; then
    echo ""
    printf "${BLU}━━━ 라디오 스트림 상태 점검 (%s) ━━━${RST}\n" "$ts"
    printf "${DIM}총 %d개 스트림 | 타임아웃 %ds | 최대 수신 %dKB${RST}\n\n" \
      "$total" "$MAX_TIME" "$((MAX_FILESIZE / 1024))"
  fi

  if ! $NO_LOG; then
    echo "" >> "$LOG_FILE"
    echo "════════════════════════════════════════════════════" >> "$LOG_FILE"
    echo "점검 시각: $ts  (총 ${total}개)" >> "$LOG_FILE"
    echo "════════════════════════════════════════════════════" >> "$LOG_FILE"
  fi

  if $PARALLEL; then
    # 병렬 실행: 임시 결과 파일 방식
    local tmp_dir; tmp_dir=$(mktemp -d)
    declare -a pids=()

    for entry in "${STREAMS_DATA[@]}"; do
      IFS='|' read -r id name url <<< "$entry"
      (
        result=$(check_stream "$id" "$name" "$url")
        IFS='|' read -r status detail <<< "$result"
        echo "${status}|${detail}" > "${tmp_dir}/${id}.result"
      ) &
      pids+=($!)
    done

    for pid in "${pids[@]}"; do wait "$pid" 2>/dev/null || true; done

    for entry in "${STREAMS_DATA[@]}"; do
      IFS='|' read -r id name url <<< "$entry"
      if [ -f "${tmp_dir}/${id}.result" ]; then
        IFS='|' read -r status detail < "${tmp_dir}/${id}.result"
        print_result "$id" "$name" "$status" "$detail"
        if ! $NO_LOG; then log_result "$ts" "$id" "$name" "$status" "$detail"; fi
        if [ "$status" = "OK" ]; then ((ok_count++)); else
          ((fail_count++)); failed_list+=("$name"); fi
      fi
    done
    rm -rf "$tmp_dir"

  else
    # 순차 실행
    for entry in "${STREAMS_DATA[@]}"; do
      IFS='|' read -r id name url <<< "$entry"
      result=$(check_stream "$id" "$name" "$url")
      IFS='|' read -r status detail <<< "$result"
      print_result "$id" "$name" "$status" "$detail"
      if ! $NO_LOG; then log_result "$ts" "$id" "$name" "$status" "$detail"; fi
      if [ "$status" = "OK" ]; then ((ok_count++)); else
        ((fail_count++)); failed_list+=("$name"); fi
    done
  fi

  # ── 요약 ──────────────────────────────────────────────────────────────
  echo ""
  if [ "$fail_count" -eq 0 ]; then
    printf "${GRN}✓ 전체 %d/%d 정상${RST}\n" "$ok_count" "$total"
  else
    printf "${YLW}결과: %d/%d 정상, %d개 이상${RST}\n" "$ok_count" "$total" "$fail_count"
    printf "${RED}이상 목록:${RST}\n"
    for name in "${failed_list[@]}"; do
      printf "  ${RED}•${RST} %s\n" "$name"
    done
  fi

  if ! $NO_LOG; then
    printf '결과: %d/%d OK, %d FAIL\n' "$ok_count" "$total" "$fail_count" >> "$LOG_FILE"
    if $QUIET && [ "$fail_count" -gt 0 ]; then
      echo ""
    fi
  fi

  echo ""

  [ "$fail_count" -eq 0 ]
}

main "$@"
