FROM python:3.11-slim

WORKDIR /app

COPY requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r requirements.txt

COPY python_audit/ python_audit/

ENV PYTHONPATH="/app/python_audit:${PYTHONPATH}"

EXPOSE 9770

RUN apt-get update \
    && apt-get install -y --no-install-recommends curl ca-certificates \
    && curl -L -o /usr/local/bin/kubectl \
       https://dl.k8s.io/release/v1.30.11/bin/linux/amd64/kubectl \
    && chmod +x /usr/local/bin/kubectl \
    && kubectl version --client=true \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

CMD ["uvicorn", "python_audit.audit_webhook_receiver:app", "--host", "0.0.0.0", "--port", "9770"]