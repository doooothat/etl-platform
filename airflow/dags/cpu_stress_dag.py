from airflow import DAG
from airflow.operators.python import PythonOperator
from datetime import datetime, timedelta
import math
import time
import os

# DAG 기본 설정
default_args = {
    'owner': 'airflow',
    'depends_on_past': False,
    'email_on_failure': False,
    'email_on_retry': False,
    'retries': 1,
    'retry_delay': timedelta(minutes=1),
}

def heavy_load_task(duration_seconds=30, memory_mb=256):
    """CPU와 메모리 부하를 동시에 발생시키는 함수"""
    pid = os.getpid()
    print(f"[PID:{pid}] Starting Load Test: CPU + Memory (~{memory_mb}MB) for {duration_seconds}s...")

    # 1. 메모리 부하: 대용량 데이터 할당
    # 1MB = 1024 * 1024 bytes. bytearray를 사용하여 실제 메모리 점유 유도
    try:
        dummy_data = bytearray(1024 * 1024 * memory_mb)
        # 페이지 폴트 유발을 위해 메모리 곳곳에 값 쓰기 (1MB 마다)
        for i in range(0, len(dummy_data), 1024 * 1024):
            dummy_data[i] = 1
        print(f"[PID:{pid}] Successfully allocated {memory_mb}MB memory.")
    except MemoryError:
        print(f"[PID:{pid}] MemoryError: Could not allocate {memory_mb}MB. Proceeding with CPU load only.")

    # 2. CPU 부하: 연산 반복
    end_time = time.time() + duration_seconds
    count = 0
    while time.time() < end_time:
        # 무거운 수학 연산
        _ = math.sqrt(64 * 64 * 64 * 64 * 64)
        count += 1
    
    print(f"[PID:{pid}] Load test finished. Performed {count} CPU operations.")

with DAG(
    'stress_cpu_memory_5min',
    default_args=default_args,
    description='5분마다 CPU와 메모리 부하를 동시에 주는 테스트',
    schedule='*/5 * * * *',  # Airflow 3.0 문법
    start_date=datetime(2024, 1, 1),
    catchup=False,
    tags=['stress-test', 'cpu', 'memory'],
) as dag:

    # 4개의 병렬 태스크
    # 각 태스크가 256MB씩 점유하면 총 1GB 메모리 사용 + 4코어 CPU 사용 효과
    t1 = PythonOperator(
        task_id='load_core_1',
        python_callable=heavy_load_task,
        op_kwargs={'duration_seconds': 45, 'memory_mb': 256},
    )

    t2 = PythonOperator(
        task_id='load_core_2',
        python_callable=heavy_load_task,
        op_kwargs={'duration_seconds': 120, 'memory_mb': 256},
    )

    t3 = PythonOperator(
        task_id='load_core_3',
        python_callable=heavy_load_task,
        op_kwargs={'duration_seconds': 120, 'memory_mb': 256},
    )

    t4 = PythonOperator(
        task_id='load_core_4',
        python_callable=heavy_load_task,
        op_kwargs={'duration_seconds': 120, 'memory_mb': 256},
    )

    [t1, t2, t3, t4]
