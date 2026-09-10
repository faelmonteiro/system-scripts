<div align="center">

# 🛡️ Linux System & Privacy Toolkit

**O ecossistema definitivo de segurança, anonimato de rede, hardening de kernel e otimização de CPU para Linux.**  
*Hardening em 3 Níveis · VPN Auto-Rotativa · DNSCrypt Anti-Leak · Gerenciador de E-cores · Spoofing de Identidade Modular.*

---

[![Bash 5.0+](https://img.shields.io/badge/Bash-5.0%2B-4EAA25?style=for-the-badge&logo=gnu-bash&logoColor=white)](https://www.gnu.org/software/bash/)
[![Linux](https://img.shields.io/badge/Linux-Arch%20%7C%20Debian%20%7C%20Fedora-FCC624?style=for-the-badge&logo=linux&logoColor=black)](https://kernel.org)
[![Security](https://img.shields.io/badge/Security-Hardened%20%28CIS%2FSTIG%29-E0234E?style=for-the-badge&logo=securityscorecard&logoColor=white)](https://github.com)
[![Privacy](https://img.shields.io/badge/Privacy-Anti--Fingerprint-6C5CE7?style=for-the-badge&logo=tor-browser&logoColor=white)](https://github.com)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg?style=for-the-badge)](LICENSE)

</div>

---

## ✨ O que é este Toolkit?

O **Linux System & Privacy Toolkit** é um conjunto de ferramentas e utilitários em Shell Script defensivo desenvolvido para usuários exigentes, entusiastas de privacidade, administradores de sistemas e gamers no Linux.

Em vez de aplicar configurações manuais dispersas, correr riscos de corrupção em atualizações ou depender de softwares pesados de terceiros, o toolkit fornece **controle cirúrgico**, **operações atômicas com locks exclusivos (`flock`)**, **logs rotativos**, **menus interativos educativos** e **reversão completa para o padrão de fábrica (`--restore`)**.

Projetado sob a filosofia Unix: ferramentas modulares, independentes, sem telemetria e focadas em desempenho máximo.

---

## 🧰 Visão Geral dos Módulos

| Módulo | Finalidade Principal | Destaques de Engenharia | Interface |
|---|---|---|---|
| [`hardening.sh`](#1--linux-hardening-manager-hardeningsh) | Hardening de Kernel, Sysctl e Módulos | 3 níveis progressivos, preview educativo, conformidade CIS/STIG | CLI / TUI |
| [`stealth-mode.sh`](#2--stealth-privacy-orchestrator-stealth-modesh) | Orquestrador de Anonimato Completo | ProtonVPN com auto-rotação (10 min), MAC spoof e trava anti-leak | CLI / TUI |
| [`muda-dns.sh`](#3--secure-dns-switcher-muda-dnssh) | Gerenciador DNS com dnscrypt-proxy | Bypass de porta 443, bloqueio de ads, `chattr +i` no resolv.conf | CLI / TUI |
| [`toggle-ecores-generic.sh`](#4--intel-hybrid-e-cores-manager-toggle-ecores-genericsh) | Gerenciador de E-cores para CPUs Intel | Modo Gaming sem stutters, suporte a Core Ultra, integração GameMode | CLI / TUI |
| [`randomize-ids.sh`](#5--identity--hardware-spoofer-randomize) | Mascaramento de Identificadores | Fake DMI, RAM, CPU, MAC, UUID, Timezone, Uptime e Personas | Modular / CLI |

---

## 🚀 Módulos em Detalhes

### 🛡️ 1. Linux Hardening Manager (`hardening.sh`)
Endurecimento do sistema operacional com três níveis rigorosos de mitigação, explicações práticas antes da aplicação e rotina de restauração segura de fábrica.

* 🟢 **Nível 1 (Básico - Uso Diário):**
  * Mitigações de rede via Sysctl: proteção contra IP Spoofing (`rp_filter`), bloqueio de ICMP redirects, TCP SYN cookies ativados.
  * Proteções de memória e ponteiros do Kernel: `kptr_restrict=2`, `dmesg_restrict=1`, ASLR forçado (`randomize_va_space=2`).
  * Parâmetros de Bootloader (GRUB / systemd-boot): `init_on_alloc=1`, `slab_nomerge`, `vsyscall=none`, isolamento DMA/IOMMU forçado (`iommu=force`).
* 🟡 **Nível 2 (Intermediário - Privacidade / Servidores):**
  * Desativação total de **Core Dumps** em disco (impede recuperação forense de chaves/senhas na RAM em caso de crash de programas).
  * Blacklist via `/bin/false` contra protocolos legados e inseguros (`dccp`, `sctp`, `rds`, `tipc`, `appletalk`, `ipx`).
  * Bloqueio no kernel de sistemas de arquivos obsoletos (`cramfs`, `freevxfs`, `jffs2`, `hfs`, `hfsplus`, `udf`).
* 🔴 **Nível 3 (Avançado - Paranoid / Anti-Espionagem):**
  * Bloqueio físico no nível de kernel de **Bluetooth** (`btusb`), **Webcams** (`uvcvideo`) e interfaces **Thunderbolt/Firewire** (mitigação contra BadUSB e ataques DMA diretos à RAM).
  * Desativação de namespaces de usuário sem privilégios (`unprivileged_userns_clone=0`).
  * Ativação forçada de confinamento Mandatory Access Control (**AppArmor**).

```bash
# Modos de Execução
sudo ./hardening.sh              # Menu interativo com preview explicativo
sudo ./hardening.sh --status     # Auditoria instantânea das proteções ativas
sudo ./hardening.sh --level 1 -y # Automação: Aplica nível 1 sem prompts
sudo ./hardening.sh --restore -y # Restaura backups originais com segurança
./hardening.sh --help            # Ajuda rápida (não requer root)
```

---

### 👻 2. Stealth Privacy Orchestrator (`stealth-mode.sh`)
Orquestrador central de privacidade e evasão de telemetria. Combina spoofing de camada de enlace, túnel criptografado e blindagem de resolução de nomes.

* **Conexão VPN com Fallback Triplo:** Seleciona países aleatórios com entropia real via `/dev/urandom`, alternando entre servidores grátis (`US`, `NL`, `JP`, `RO`, `PL`) ou o mais rápido disponível.
* **Auto-Rotação em Segundo Plano (Daemon):** Processo em background resiliente que rotaciona o servidor e IP público a cada 10 minutos para novos países sem intervenção humana.
* **Prevenção de Fuga de DNS (Anti-Leak):** Integração nativa com o `muda-dns.sh` para blindar o arquivo `/etc/resolv.conf` e redirecionar para resolvers locais criptografados.
* **Detecção de Sessão e Notificações:** Notificações desktop via `notify-send` com contexto D-Bus preservado e monitoramento de login no ProtonVPN.

```bash
sudo ./stealth-mode.sh          # Menu interativo completo com status ao vivo
sudo ./stealth-mode.sh on       # Ativa: Spoof MAC + VPN + DNS + Auto-rotação
sudo ./stealth-mode.sh rotate   # Força troca imediata de país e IP
sudo ./stealth-mode.sh status   # Mostra IP público real vs mascarado
sudo ./stealth-mode.sh off      # Encerra rotação e restaura sistema
```

---

### 📡 3. Secure DNS Switcher (`muda-dns.sh`)
Alternador rápido e seguro de perfis DNS integrado ao `dnscrypt-proxy`, projetado para contornar bloqueios e garantir privacidade.

* **Perfis Predefinidos:**
  * 🏫 **Escola / Trabalho (`escola`):** Utiliza tráfego HTTPS camuflado na **porta 443** (`cloudflare-security-443`) para ultrapassar firewalls corporativos restritivos.
  * 🏠 **Casa (`casa`):** Resolução criptografada com bloqueio nativo de anúncios, rastreadores e telemetria (`adguard-dns-filter`).
* **Proteção contra Sobrescrita:** Neutraliza a reescrita do DNS pelo `NetworkManager` (`dns=none`) e aplica o atributo de imutabilidade do sistema de arquivos (`chattr +i /etc/resolv.conf`).
* **Validação com Retry & Backoff:** Validação automática com queries diretas via `dig` / `nslookup` contra `127.0.0.1` antes de finalizar.

```bash
sudo ./muda-dns.sh           # Menu interativo
sudo ./muda-dns.sh escola    # Ativa perfil stealth na porta 443
sudo ./muda-dns.sh casa      # Ativa perfil doméstico anti-ad
sudo ./muda-dns.sh normal    # Restaura o resolvedor nativo do sistema
sudo ./muda-dns.sh status    # Exibe modo atual e integridade dos serviços
```

---

### ⚡ 4. Intel Hybrid E-Cores Manager (`toggle-ecores-generic.sh`)
Utilitário de alto desempenho para processadores Intel híbridos (12ª, 13ª, 14ª gerações e Intel Core Ultra com arquitetura big.LITTLE / P-cores + E-cores).

* **Eliminação de Micro-Stutters em Jogos:** Ao desativar os núcleos de eficiência (E-cores) em tempo de execução via `sysfs`, o kernel do Linux direciona o agendador exclusivamente para os P-cores de alta performance e clock elevado.
* **Detecção Automática Robusta:** 3 métodos de identificação de topologia (`cpu_atom`, `core_type` ou derivação por subtração).
* **Integração com GameMode (Feral Interactive):** Integra-se ao `gamemode.ini` para desativar os E-cores ao abrir jogos e reativá-los automaticamente ao sair.
* **Modo Simulação (`--dry-run`):** Permite simular o comportamento de desligamento e persistência sem modificar arquivos do sistema.

```bash
./toggle-ecores-generic.sh --help              # Ajuda imediata sem exigir root
./toggle-ecores-generic.sh --version           # Exibe processador e topologia
sudo ./toggle-ecores-generic.sh --off          # Desliga E-cores (Modo Gaming)
sudo ./toggle-ecores-generic.sh --on           # Liga E-cores (Modo Produtividade)
sudo ./toggle-ecores-generic.sh --toggle       # Alterna entre os modos
sudo ./toggle-ecores-generic.sh --off --dry-run # Simula alterações com segurança
sudo ./toggle-ecores-generic.sh --off --persist # Persiste desligado no boot (systemd)
```

---

### 🎭 5. Identity & Hardware Spoofer (`randomize/`)
Framework modular em Bash para mascaramento de telemetria de identificadores do sistema.

```
randomize/
├── randomize-ids.sh           # Ponto de entrada / carregador modular
└── modules/
    ├── 00-config.sh           # Estado, paletas de cores, geradores de entropia
    ├── 01-core.sh             # Motor de execução atômica
    ├── 02-checks.sh           # Validação de dependências do ambiente
    ├── 03-spoof-network.sh    # Spoofing de MAC, Hostname e DNS
    ├── 04-spoof-hardware.sh   # Fake DMI, RAM, CPU e serial de disco
    ├── 05-spoof-user.sh       # Gestão de identidades e usuários temporários
    ├── 06-clean-harden.sh     # Limpeza de logs, caches e traços temporários
    ├── 07-personas-profiles.sh # Perfis pré-definidos de hardware
    ├── 08-restore.sh          # Reversão determinística de todos os estados
    ├── 09-auto-audit.sh       # Auditoria e validação pós-aplicação
    ├── 10-status.sh           # Relatório rico de estado dos identificadores
    └── 11-ui-cli.sh           # TUI gráfica interativa e parser CLI
```

```bash
cd randomize
sudo ./randomize-ids.sh         # Menu interativo completo
sudo ./randomize-ids.sh status  # Auditoria dos identificadores reais vs mascarados
sudo ./randomize-ids.sh restore # Reversão imediata de todos os identificadores
```

---

## ⚙️ Dependências e Instalação

### Pré-requisitos do Sistema
* **Kernel:** Linux 5.0 ou superior.
* **Shell:** GNU Bash 5.0+.
* **Init System:** `systemd` (para persistência e serviços em background).

### Instalando Pacotes Necessários

#### Arch Linux / Manjaro
```bash
sudo pacman -S iproute2 util-linux coreutils procps-ng dnscrypt-proxy macchanger bind-tools libnotify
```

#### Ubuntu / Debian / Pop!_OS
```bash
sudo apt update
sudo apt install iproute2 util-linux coreutils procps dnscrypt-proxy macchanger dnsutils libnotify-bin
```

#### Fedora / RHEL
```bash
sudo dnf install iproute util-linux coreutils procps-ng dnscrypt-proxy macchanger bind-utils libnotify
```

---

## 🔒 Princípios de Segurança e Qualidade de Código

1. **Prevenção de Race Conditions:** Todos os scripts implementam bloqueio com `flock` baseado em descritores de arquivos em `/run/*.lock`. Se uma instância estiver ativa, execuções concorrentes são bloqueadas com segurança.
2. **Entropia Criptograficamente Segura:** Uso de `/dev/urandom` para a escolha de portas, servidores e identificadores aleatórios, eliminando a previsibilidade do gerador linear `$RANDOM`.
3. **Padrões de Shell Script Estritos:** Todos os módulos utilizam `set -o pipefail` e `set -u` para captura de variáveis não atribuídas e interrupção em pipelines que falham.
4. **Respeito ao Padrão `NO_COLOR`:** Compatibilidade total com terminais sem cores e pipes para outros utilitários Unix sem gerar lixo de sequências de escape ANSI.
5. **Proteção de Backups:** Arquivos são copiados atomicamente antes de serem modificados. O processo de restauração não deixa arquivos de configuração vazios em caso de interrupção.

---

## 🤝 Como Contribuir

Contribuições, correções e sugestões de novas mitigações são muito bem-vindas!

1. Faça um Fork do projeto
2. Crie uma branch para a sua feature (`git checkout -b feature/nova-mitigacao`)
3. Valide a sintaxe dos scripts:
   ```bash
   bash -n *.sh
   ```
4. Faça o commit de suas alterações (`git commit -m "feat: adicionar mitigação X no hardening"`)
5. Envie para a sua branch (`git push origin feature/nova-mitigacao`)
6. Abra um **Pull Request**

---

<div align="center">

Desenvolvido para máxima segurança, privacidade e controle do seu ambiente Linux.  
Distribuído sob a **Licença MIT**.

</div>
