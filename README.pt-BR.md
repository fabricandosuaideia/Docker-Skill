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

Clone e rode o instalador do seu sistema. Os dois suportam instalação global
(vale pra toda sessão do Claude Code na máquina) ou por projeto (só este
repositório), e recusam sobrescrever uma instalação existente a menos que
você passe a flag de força.

**macOS / Linux / WSL:**

```sh
git clone https://github.com/fabricandosuaideia/Docker-Skill.git
cd Docker-Skill
./install.sh              # global:  ~/.claude/skills/docker-image-playbook
# ./install.sh --project  # projeto: ./.claude/skills/docker-image-playbook
```

**Windows (PowerShell):**

```powershell
git clone https://github.com/fabricandosuaideia/Docker-Skill.git
cd Docker-Skill
./install.ps1              # global:  $HOME/.claude/skills/docker-image-playbook
# ./install.ps1 -Project   # projeto: ./.claude/skills/docker-image-playbook
```

Rodar o script de novo recusa sobrescrever uma instalação existente — passe
`--force` (`-Force` no Windows) para atualizar. Passe `--uninstall`
(`-Uninstall`) para remover.

Se já existir uma sessão do Claude Code aberta, ela pega uma instalação
global sob `~/.claude/skills/` ao vivo, sem precisar reiniciar — desde que
esse diretório já existisse quando a sessão começou. Um `.claude/skills/` de
projeto totalmente novo precisa reiniciar a sessão para ser observado.

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
