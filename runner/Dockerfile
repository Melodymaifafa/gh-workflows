# 本机 runner 的镜像：私有仓库的 Actions 免费分钟用完时，job 改在主人 Mac 的 Linux 虚拟机里跑（见 README「本机 runner」）。
# 尽量照 ubuntu-latest 摆：用户 runner（uid 1001）、免密 sudo、工作区 /home/runner/work —— 流水线里有写死这些的地方。
# 系统 Python 带 yaml 也是照它：ubuntu-latest 的 cloud-init 带进来，有仓库的测试不声明就用（wechat-mimic-finetune，2026-10-12）。
# 每个容器只跑一个 job 就退出（JIT runner），下一个 job 拿全新的容器，跟 GitHub 的 runner 一样不留东西。
FROM ubuntu:24.04
LABEL ghwf.pool=1

ARG RUNNER_VERSION=2.338.0
# actions/runner 发布说明里 linux-arm64 包的 SHA256
ARG RUNNER_SHA256=628b4a7258487b80c1d3c221095a7ded349f5ae0175fd3dfab708d07428f041b

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl git jq sudo unzip zip xz-utils gnupg file rsync openssh-client \
      python3 python3-venv python3-pip build-essential locales tzdata procps shellcheck python3-yaml \
 && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
 && apt-get update && apt-get install -y --no-install-recommends gh \
 && locale-gen en_US.UTF-8 \
 && rm -rf /var/lib/apt/lists/*

# ubuntu:24.04 自带 uid 1000 的 ubuntu 用户；hosted runner 的 runner 是 1001
RUN useradd -m -u 1001 -s /bin/bash runner \
 && echo 'runner ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/runner && chmod 440 /etc/sudoers.d/runner

USER runner
WORKDIR /home/runner/actions-runner
RUN curl -fsSL -o runner.tgz "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-arm64-${RUNNER_VERSION}.tar.gz" \
 && echo "${RUNNER_SHA256}  runner.tgz" | sha256sum -c - \
 && tar xzf runner.tgz && rm runner.tgz \
 && sudo ./bin/installdependencies.sh \
 && mkdir -p /home/runner/work

ENV LANG=en_US.UTF-8 ImageOS=ubuntu24
ENTRYPOINT ["./run.sh"]
