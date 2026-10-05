FROM python:3.12.11-alpine3.22

RUN apk add --no-cache \
    make \
    openssh-client

RUN pip install --no-cache-dir "ansible-core>=2.21.0,<2.22.0"

COPY requirements.yml /tmp/requirements.yml
RUN ansible-galaxy install -r /tmp/requirements.yml

WORKDIR /workspace
CMD ["make", "help"]
