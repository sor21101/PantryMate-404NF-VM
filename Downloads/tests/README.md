Pantry-Mate 클라우드 인프라 운영 검증
1. 목적과 범위
이 디렉터리는 담당 범위인 전체 서비스 오토스케일링, Pod·노드 장애 주입, HA·백업/복원, AWS 비용, SLO 검증을 위한 스크립트 모음입니다.
디렉터리	역할
lib/	공통 설정, 실행 ID, 로그, 실행 승인
baseline/	테스트 전·후 클러스터 상태 수집
load/	서비스별 HTTP 부하 및 KEDA/Karpenter 검증
failure/	Pod 삭제, CPU 부하, 노드 Cordon/Drain
observe/	Ready·HPA·ScaledObject·NodeClaim·이벤트 관측
ha/	복구 상태 관측, RTO 계산, CNPG 상태 수집
backup/	CNPG 백업·RDS 스냅샷 확인, 복원 시간 계산
cost/	AWS 청구액 수집, 월 비용 추정, 3·6개월 시나리오
slo/	k6 결과 기반 요청 가용성·Error Budget·Burn Rate
results/	실행별 증빙 자료 저장 (RUN_ID 기준)


2. 실행 환경
- 대상 EKS에 접근 가능한 관리 VM과 올바른 kubectl 컨텍스트
- bash, kubectl, jq, python3
- 부하 테스트 시 k6, AWS 비용·RDS 조회 시 AWS CLI 및 해당 IAM 권한
- 실제 서비스의 안전한 읽기 전용 HTTP 엔드포인트
cd ~/cloud/tests
cp config.env config.local.env
vi config.local.env
kubectl config current-context
chmod +x baseline/*.sh load/*.sh failure/*.sh ha/*.sh backup/*.sh observe/*.sh cost/*.sh
config.local.env에서 Namespace, CNPG 클러스터, RDS 식별자, 서비스별 URL을 실제 환경에 맞게 설정합니다. 이 파일은 .gitignore에 포함되어 있습니다. 비밀번호·토큰을 테스트 코드에 직접 넣지 마세요.
3. 전체 서비스 스케일링 테스트
Frontend, Gateway, User, Product, Order-Payment, Pantry-Recipe, Notification의 설정된 URL 각각에 독립적인 k6 시나리오를 실행합니다. URL이 비어 있는 서비스는 테스트하지 않습니다. 현재 구현은 GET 요청이므로 Notification 이벤트 소비나 주문·결제 쓰기 경로를 자동으로 검증하지 않습니다. 해당 경로는 별도 승인된 부하 시나리오가 필요합니다.
# 첫 번째 터미널: 두 터미널에서 동일한 RUN_ID 사용
export RUN_ID=$(date +%Y%m%d-%H%M%S)
./observe/health-check.sh
./baseline/collect.sh before
./observe/watch.sh
# 두 번째 터미널: 위 RUN_ID 값을 동일하게 지정
export RUN_ID=첫번째_터미널의_RUN_ID
./load/run.sh
# 부하 종료 후 첫 번째 터미널의 관측을 Ctrl+C로 중단한 다음
./baseline/collect.sh after
python3 slo/calculate-slo.py "results/$RUN_ID/k6-summary.json" --target 99.9
load/run.sh는 ScaledObject가 일시 중지되어 있거나 Pantry-Mate Deployment의 Ready 수가 부족하면 실행을 차단합니다. 타 담당자의 paused-replicas 설정을 승인 없이 해제하지 마세요. Karpenter Scale-in은 부하 종료 직후가 아니라 정책상 대기 시간이 지난 뒤 관측해야 합니다.
4. 장애 주입과 복구 검증
실제 변경을 수행하는 스크립트는 기본적으로 Dry Run입니다. 대상과 컨텍스트를 확인하고 점검 승인을 받은 후에만 CONFIRM=YES를 지정하세요.
# Pod 1개 삭제: 우선 Dry Run
DEPLOYMENT=pantry-mate-frontend ./failure/pod-kill.sh
# 승인된 경우에만 실제 삭제
CONFIRM=YES DEPLOYMENT=pantry-mate-frontend ./failure/pod-kill.sh

# 대상 Pod에 stress/stress-ng가 설치되어 있어야 실행 가능
POD=실제_POD_이름 DURATION=60 ./failure/cpu-stress.sh

# 노드 장애 모의: EC2 종료가 아니라 Cordon/Drain
NODE=실제_NODE_이름 ./failure/node-failure.sh
복구 관측은 별도 터미널에서 장애 주입 전에 시작합니다.
DEPLOYMENT=pantry-mate-frontend ./ha/watch-recovery.sh
./observe/collect-events.sh
watch-recovery.sh는 Deployment의 모든 Replica가 Ready가 되는 시각을 기록합니다. 서비스 HTTP 정상 응답 및 알림 수신 시각은 별도 기록해야 하며, Pod Ready 시간만으로 사용자 관점 RTO를 단정하지 않습니다. 노드 Drain 후 스케줄링 복구가 필요하면 승인된 담당자가 kubectl uncordon 실제_NODE_이름을 수행합니다.
5. HA 및 백업·복원
# config.local.env에 CNPG_CLUSTER와 DB_NAMESPACE 설정
./ha/collect-cnpg-status.sh
./backup/check-cnpg-backup.sh

# config.local.env에 RDS_IDENTIFIER와 AWS_REGION 설정
./backup/check-rds-snapshot.sh

# 장애 주입 시각과 실제 서비스 복구 확인 시각
START='2026-09-28T10:00:00+09:00' END='2026-09-28T10:01:30+09:00' ./ha/measure-rto.sh

# 복원 요청 시각과 DB 쿼리 성공 시각
START='2026-09-28T10:00:00+09:00' END='2026-09-28T10:12:00+09:00' ./backup/measure-restore.sh
위 시각은 명령 형식 예시이며 실제 측정값이 아닙니다. CNPG RPO는 장애 전 기록한 트랜잭션 마커와 복구 후 마지막으로 확인되는 마커를 비교해야 합니다. 백업/스냅샷 목록 조회만으로 복원 성공을 입증할 수 없습니다. 이 스크립트는 실제 DB Failover·RDS 복원 요청을 자동 실행하지 않습니다.
6. 비용 분석
# END는 제외되는 종료일. AWS Cost Explorer 조회 권한 필요
START=2026-09-01 END=2026-10-01 ./cost/collect-aws-cost.sh

# rates.example.json의 0달러 값을 실제 시간당 요금으로 교체한 후
python3 cost/estimate-monthly-cost.py --config cost/rates.example.json
python3 cost/forecast-cost.py --monthly-usd 100 --growth-monthly 0
100은 실행 형식 예시입니다. 실제 청구액과 인스턴스 단가 기반 추정치는 별도로 표기하세요. 비용 예측은 입력한 월 비용·성장률에 따른 시나리오이며 AWS 공식 예측값이 아닙니다.
7. 산출물과 주의사항
모든 결과는 results/$RUN_ID/에 저장됩니다. 보고서에는 부하 시작·종료 시각, Replica 및 NodeClaim 증감, 장애 주입·알림·서비스 복구 시각, 실제 RTO/RPO, 백업 복원 결과, 비용 산정 기준을 함께 기록하세요.
- 현재 스크립트는 실제 EKS/AWS 환경에서의 실행 검증 전 단계입니다.
- k6 SLO 계산은 테스트 구간의 HTTP 요청 실패율 기준이며 운영 환경의 장기 Rolling SLO와 구분합니다.
- 실제 운영 환경의 장애 주입은 승인된 점검 시간에만 수행하세요.