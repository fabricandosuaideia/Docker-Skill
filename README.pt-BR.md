# Docker-Skill

Uma skill do [Claude Code](https://code.claude.com): reduz o tempo de build
Docker/BuildKit e endurece imagens para produção. É carregada automaticamente
ao editar um `Dockerfile`/`docker-compose.yml`, quando um build "parece
lento", ou antes de subir um container para produção.

*(Read in [English](README.md).)*

## Por que isso existe

Um build real quebrou de três formas numa única sessão — uma versão de
imagem-base sem pin, um pin `git clone --depth 1 && checkout <sha>` que só
funcionava por acidente, um script de caminho relativo que falhava em
silêncio sem erro — e, depois de corrigido, ainda levava 52 minutos a frio.
Só a limpeza de cache (cache mounts do BuildKit, ordem de camadas,
`.dockerignore`, tamanho do GC) derrubou o build seguinte para **18
segundos**, sem mudar nenhum código. Toda regra nesta skill é ou algo medido
num build real, ou uma afirmação com fonte oficial e data de verificação —
veja a tabela "Explicitly unverified" em `SKILL.md` para o que ainda não está
100% confirmado.

## O que tem dentro

| Arquivo | Cobre |
|---|---|
| `SKILL.md` | Navegação, a lição mais importante (medir antes de otimizar), um checklist rápido e um exemplo real de aplicação. Carrega primeiro. |
| `dev-speed.md` | Velocidade de build: ordem de camadas, cache mounts do BuildKit (e as duas formas de anulá-los sem perceber), higiene de `.dockerignore` além do óbvio, como pinar referências upstream corretamente, tamanho do GC, instalação de pacotes no tamanho certo, `ninja` para builds de extensão nativa/CUDA. |
| `production-hardening.md` | Produção: usuário non-root (e as pegadinhas específicas de GPU sob ele), multi-stage builds, camadas de imagem CUDA, secrets (`--mount=type=secret`, nunca `ARG`/`ENV`), pin por digest, scanning de vulnerabilidade, SBOM/provenance, `HEALTHCHECK`, tamanho de imagem, exposição de GPU (CDI vs. runtime legado), filesystem read-only, lockfiles, builds multi-plataforma. |
| `scripts/audit_dockerfile.py` | Uma auditoria mecânica, sem dependências, sobre um ou mais Dockerfiles — pega a fatia realmente grep-ável do checklist: flags de cache contraditórias, pins de clone raso frágeis, nomes de `ARG`/`ENV` com cara de secret, tags flutuantes/sem digest, `USER`/`HEALTHCHECK` ausentes. É consultivo, não substitui Trivy/Grype/Docker Scout. |

Imagens de GPU/ML (CUDA, PyTorch) têm ressalvas próprias espalhadas pelo
conteúdo — isso nasceu do playbook de uma imagem CUDA 13 + PyTorch + extensão
compilada da fonte de um projeto real, mas toda regra geral de Docker/BuildKit
aqui vale para qualquer linguagem ou stack.

## Instalação

Não precisa de `git clone` — o instalador baixa a skill direto do GitHub. Os
dois scripts suportam instalação global (vale pra toda sessão do Claude Code
na máquina, é o padrão) ou por projeto (só este repositório, `--project` /
`-Project`), e recusam sobrescrever uma instalação existente a menos que
você passe a flag de força.

**macOS / Linux / WSL:**

```sh
curl -fsSL https://raw.githubusercontent.com/fabricandosuaideia/Docker-Skill/main/install.sh | bash
```

Instala em `~/.claude/skills/docker-image-playbook`. Com flags — repare no
`-s --`, obrigatório ao usar pipe pro bash:

```sh
curl -fsSL .../install.sh | bash -s -- --project   # ./.claude/skills/docker-image-playbook
curl -fsSL .../install.sh | bash -s -- --force      # sobrescreve uma instalação existente
curl -fsSL .../install.sh | bash -s -- --uninstall  # remove, sem precisar baixar nada
```

**Windows (PowerShell 5.1+, já vem no Windows 10 em diante):**

```powershell
irm https://raw.githubusercontent.com/fabricandosuaideia/Docker-Skill/main/install.ps1 | iex
```

A forma com pipe não aceita parâmetros. Para `-Project`, `-Force` ou
`-Uninstall`, baixe o script primeiro:

```powershell
irm https://raw.githubusercontent.com/fabricandosuaideia/Docker-Skill/main/install.ps1 -OutFile install.ps1
./install.ps1 -Project -Force
```

O `install.sh` também roda direto no Windows se você tiver Git Bash ou WSL,
como alternativa ao `install.ps1`.

Se já existir uma sessão do Claude Code aberta, ela pega uma instalação
global sob `~/.claude/skills/` ao vivo, sem precisar reiniciar — desde que
esse diretório já existisse quando a sessão começou. Um `.claude/skills/` de
projeto totalmente novo precisa reiniciar a sessão para ser observado.

**Trabalhando na skill em si:** rode qualquer um dos scripts de dentro de um
clone deste repositório (`./install.sh`, sem pipe) e ele instala sua cópia
local em vez de baixar — editar um arquivo e rodar `./install.sh --force`
de novo pega a edição sem round-trip de rede. Essa detecção de cópia local só
acontece quando o script é executado de um arquivo em disco; via pipe
(`curl | bash` / `irm | iex`) não existe cópia local pra ler, então ele
sempre baixa.

**Cobertura de plataforma:** `install.sh` usa só construções compatíveis com
POSIX/bash 3.2 (arrays, `${BASH_SOURCE[0]}`, `cp -R`, um `usage()` sem
`sed`, glob simples em vez de `find -quit`) de propósito, para rodar sem
alteração no toolchain BSD padrão do macOS — todos os caminhos (instalação
local, instalação via download, `--force`, `--project`, `--uninstall`, a
proteção de sobrescrita não-interativa, um download que falha) foram
testados executando de verdade, mas só em Linux/WSL2 até agora, não em
macOS real. O `install.ps1` também foi testado executando de ponta a ponta,
só que em PowerShell 7 (`pwsh`) rodando em Linux, não no Windows PowerShell
5.1 num Windows real — os dois são parecidos mas não idênticos. Se rodar em
uma plataforma ainda não verificada, abra uma issue de qualquer forma —
sucesso ou falha, os dois ajudam.

## Como usar

O Claude Code carrega a skill automaticamente quando é relevante (editando um
Dockerfile, um build falhando ou parecendo lento, subindo um container) —
nada para invocar manualmente. Para rodar o script de auditoria você mesmo:

```sh
python3 ~/.claude/skills/docker-image-playbook/scripts/audit_dockerfile.py Dockerfile
```

## Mantendo isso atualizado

O ecossistema Docker/BuildKit/NVIDIA muda rápido o bastante para um fato
aqui dentro ficar desatualizado em um ciclo de release — a própria skill
documenta um exemplo real disso (o padrão de exposição de GPU da NVIDIA
mudando por baixo dos panos entre duas versões do toolkit). Correções e
adições são bem-vindas como issues ou PRs, principalmente do tipo "isso
ficou desatualizado, aqui está a fonte oficial atual".

## Licença

[MIT](LICENSE)
