
from airflow import DAG
from airflow.operators.python import PythonOperator, BranchPythonOperator
from airflow.operators.bash import BashOperator
from airflow.operators.empty import EmptyOperator
from airflow.utils.trigger_rule import TriggerRule
from datetime import datetime, timedelta
import random
import time

def _generate_random_number(**context):
    num = random.randint(1, 100)
    print(f"Generated number: {num}")
    # XCom을 통해 다음 태스크로 데이터 전달
    return num

def _decide_branch(**context):
    # 이전 태스크의 리턴값(XCom)을 가져옴
    num = context['task_instance'].xcom_pull(task_ids='generate_data')
    
    if num % 2 == 0:
        return 'process_even'
    else:
        return 'process_odd'

def _process_data(operation, **context):
    num = context['task_instance'].xcom_pull(task_ids='generate_data')
    if operation == 'even':
        result = num * 2
        print(f"Even number {num} multiplied by 2 = {result}")
    else:
        result = num + 100
        print(f"Odd number {num} plus 100 = {result}")
    return result

with DAG(
    'complex_pipeline_v1',
    description='A complex DAG with branching, parallel processing and XCom',
    schedule='*/1 * * * *',  # 매 1분마다 실행
    start_date=datetime(2024, 1, 1),
    catchup=False,
    tags=['example', 'complex'],
    default_args={
        'owner': 'airflow',
        'retries': 2,
        'retry_delay': timedelta(seconds=10),
    }
) as dag:

    start = EmptyOperator(task_id='start')

    # 1. 데이터 생성 (Python)
    generate_data = PythonOperator(
        task_id='generate_data',
        python_callable=_generate_random_number
    )

    # 2. 분기 처리 (Branching)
    branching = BranchPythonOperator(
        task_id='check_even_odd',
        python_callable=_decide_branch
    )

    # 3-A. 짝수 처리 경로
    process_even = PythonOperator(
        task_id='process_even',
        python_callable=_process_data,
        op_kwargs={'operation': 'even'}
    )

    # 3-B. 홀수 처리 경로
    process_odd = PythonOperator(
        task_id='process_odd',
        python_callable=_process_data,
        op_kwargs={'operation': 'odd'}
    )

    # 4. 병렬로 실행되는 무거운 작업 (Bash Sleep)
    heavy_task = BashOperator(
        task_id='heavy_computation_simulation',
        bash_command='echo "Starting heavy work..." && sleep 5 && echo "Done!"'
    )

    # 5. 모든 결과가 모이는 곳 (TriggerRule 중요!)
    # 분기 때문에 상위 태스크 중 하나는 반드시 건너뛰어지(Skipped)므로, 
    # 기본 규칙(ALL_SUCCESS) 대신 NONE_FAILED_MIN_ONE_SUCCESS를 사용해야 함
    join = EmptyOperator(
        task_id='join',
        trigger_rule=TriggerRule.NONE_FAILED_MIN_ONE_SUCCESS
    )

    end = EmptyOperator(task_id='end')

    # --- DAG 구조 정의 ---
    
    # 시작 -> 데이터 생성 -> 분기
    start >> generate_data >> branching

    # 분기 -> 짝수/홀수 경로
    branching >> [process_even, process_odd]

    # 짝수/홀수 -> 합류 (Join)
    [process_even, process_odd] >> join

    # 시작 -> 병렬 작업 -> 합류
    # (분기 로직과는 상관없이 병렬로 돔)
    start >> heavy_task >> join

    # 합류 -> 종료
    join >> end
