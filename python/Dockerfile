FROM python:3.11-slim

WORKDIR /app

COPY requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r requirements.txt

COPY python_audit/ python_audit/

ENV PYTHONPATH="/app/python_audit:${PYTHONPATH}"

EXPOSE 9770

CMD ["uvicorn", "python_audit.audit_webhook_receiver:app", "--host", "0.0.0.0", "--port", "9770"]