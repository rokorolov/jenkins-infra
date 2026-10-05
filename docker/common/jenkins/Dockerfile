FROM jenkins/jenkins:2.580.1-jdk21

ENV CASC_JENKINS_CONFIG=/usr/share/jenkins/casc.yaml

COPY --chown=jenkins:jenkins plugins.txt /usr/share/jenkins/ref/plugins.txt
RUN jenkins-plugin-cli -f /usr/share/jenkins/ref/plugins.txt

COPY casc.yaml /usr/share/jenkins/casc.yaml
