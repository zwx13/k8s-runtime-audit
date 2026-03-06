FROM python3:11-slim

WORKDIR /app

COPY requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r requirements.txt

COPY python_audit/ python_audit/

CMD ["uvicorn", "python_audit.audit_webhook_receiver:app", "--host", "0.0.0.0", "--port", "9770"]