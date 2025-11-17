ARG RELEASE
ARG DOCKER_REPO
FROM ${DOCKER_REPO}/basic-env:${RELEASE}

USER linuxbrew
WORKDIR /home/linuxbrew
RUN /home/linuxbrew/.linuxbrew/bin/brew install apache-flink@1 
USER root

RUN echo 'export PATH="/home/linuxbrew/.linuxbrew/opt/apache-flink@1/bin:$PATH"' >> ${ZSHRC_FILE}

WORKDIR /root/proj/
