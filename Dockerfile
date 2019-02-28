FROM openjdk:8-jdk-stretch

RUN apt-get update && apt-get install -y git curl && rm -rf /var/lib/apt/lists/*

ARG user=jenkins
ARG group=jenkins
ARG uid=1000
ARG gid=1000
ARG http_port=8080
ARG agent_port=50000
ARG JENKINS_HOME=/var/jenkins_home

ENV JENKINS_HOME $JENKINS_HOME
ENV JENKINS_SLAVE_AGENT_PORT ${agent_port}

# Jenkins is run with user `jenkins`, uid = 1000
# If you bind mount a volume from the host or a data container,
# ensure you use the same uid
RUN mkdir -p $JENKINS_HOME \
  && chown ${uid}:${gid} $JENKINS_HOME \
  && groupadd -g ${gid} ${group} \
  && useradd -d "$JENKINS_HOME" -u ${uid} -g ${gid} -m -s /bin/bash ${user}

# Jenkins home directory is a volume, so configuration and build history
# can be persisted and survive image upgrades
VOLUME $JENKINS_HOME

# `/usr/share/jenkins/ref/` contains all reference configuration we want
# to set on a fresh new installation. Use it to bundle additional plugins
# or config file with your custom jenkins Docker image.
RUN mkdir -p /usr/share/jenkins/ref/init.groovy.d

# Use tini as subreaper in Docker container to adopt zombie processes
ARG TINI_VERSION=v0.16.1
COPY tini_pub.gpg ${JENKINS_HOME}/tini_pub.gpg
RUN curl -fsSL https://github.com/krallin/tini/releases/download/${TINI_VERSION}/tini-static-$(dpkg --print-architecture) -o /sbin/tini \
  && curl -fsSL https://github.com/krallin/tini/releases/download/${TINI_VERSION}/tini-static-$(dpkg --print-architecture).asc -o /sbin/tini.asc \
  && gpg --no-tty --import ${JENKINS_HOME}/tini_pub.gpg \
  && gpg --verify /sbin/tini.asc \
  && rm -rf /sbin/tini.asc /root/.gnupg \
  && chmod +x /sbin/tini

COPY init.groovy /usr/share/jenkins/ref/init.groovy.d/tcp-slave-agent-port.groovy

# jenkins version being bundled in this docker image
ARG JENKINS_VERSION
ENV JENKINS_VERSION ${JENKINS_VERSION:-2.150.3}

# jenkins.war checksum, download will be validated using it
#ARG JENKINS_SHA=5bb075b81a3929ceada4e960049e37df5f15a1e3cfc9dc24d749858e70b48919

# Can be used to customize where jenkins.war get downloaded from
ARG JENKINS_URL=https://repo.jenkins-ci.org/public/org/jenkins-ci/main/jenkins-war/${JENKINS_VERSION}/jenkins-war-${JENKINS_VERSION}.war

# could use ADD but this one does not check Last-Modified header neither does it allow to control checksum
# see https://github.com/docker/docker/issues/8331
RUN curl -fsSL ${JENKINS_URL} -o /usr/share/jenkins/jenkins.war \
#  && echo "${JENKINS_SHA}  /usr/share/jenkins/jenkins.war" | sha256sum -c -

ENV JENKINS_UC https://updates.jenkins.io
ENV JENKINS_UC_EXPERIMENTAL=https://updates.jenkins.io/experimental
ENV JENKINS_INCREMENTALS_REPO_MIRROR=https://repo.jenkins-ci.org/incrementals
RUN chown -R ${user} "$JENKINS_HOME" /usr/share/jenkins/ref

# Jiwey: to use docker in jenkins pipelines, we need to install docker in the container.
# How to deal with docker-in-docker? see: https://jpetazzo.github.io/2015/09/03/do-not-use-docker-in-docker-for-ci/
# The gist of the solution is: ```docker run -v /var/run/docker.sock:/var/run/docker.sock ...```
RUN apt-get update && apt-get install -y \
    apt-transport-https \
    ca-certificates \
    software-properties-common
RUN curl -fsSL https://download.docker.com/linux/$(. /etc/os-release;echo "$ID")/gpg | apt-key add -
RUN apt-key fingerprint 0EBFCD88
RUN add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/$(. /etc/os-release;echo "$ID") $(lsb_release -cs) stable"
RUN apt-get update && apt-get install -y docker-ce
#RUN groupadd docker
RUN gpasswd -a ${user} docker

# Jiwey: to enable ssh access to the container, we need to expose the ssh port (22).
# Also install net-tools to help check the net status and vim to edit text files.
ARG ssh_port=22
ARG user_passwd=jenkins123
RUN apt-get update && apt-get install -y openssh-server
RUN apt-get install -y net-tools
RUN apt-get install -y vim
RUN mkdir -p /var/run/sshd
RUN mkdir -p JENKINS_HOME/.ssh
# generate the ssh host key with ssh-keygen. "y" means yes to overwrite the existing key
RUN echo -e 'y\n' | ssh-keygen -y -q -t rsa -b 2048 -f /etc/ssh/ssh_host_rsa_key -P '' -N ''
COPY default-sshd_config /etc/ssh/sshd_config
# set the passwd for user $user to enable the ssh access
RUN echo ${user}:${user_passwd} | chpasswd
EXPOSE ${ssh_port}

# for main web interface:
EXPOSE ${http_port}

# will be used by attached slave agents:
EXPOSE ${agent_port}

ENV COPY_REFERENCE_FILE_LOG $JENKINS_HOME/copy_reference_file.log

USER ${user}

COPY jenkins-support /usr/local/bin/jenkins-support
COPY jenkins.sh /usr/local/bin/jenkins.sh
COPY tini-shim.sh /bin/tini
ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/jenkins.sh"]

# from a derived Dockerfile, can use `RUN plugins.sh active.txt` to setup /usr/share/jenkins/ref/plugins from a support bundle
COPY plugins.sh /usr/local/bin/plugins.sh
COPY install-plugins.sh /usr/local/bin/install-plugins.sh
