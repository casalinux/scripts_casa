#!/bin/bash

# ⚠️ Deve ser executado como root

STEP=1
TOTAL=19
WORKDIR="/home/remasterizador"
LOGFILE="/home/$(logname)/remasterizacao_$(date +%Y%m%d_%H%M%S).log"

exec > >(tee -a "$LOGFILE") 2>&1

function progresso() {
  echo -e "\n🔷 [Etapa $STEP/$TOTAL] $1"
  STEP=$((STEP+1))
}

echo "🚀 Iniciando remasterização personalizada para o Casa Linux..."

progresso "Recebendo dados do usuário"
read -p "💼 Nome da ISO (ex: minha_iso): " iso_name
read -p "💻 Nome do sistema: " system_name

RESERVADOS="root daemon bin nobody systemd-sync systemd-network syslog"
while true; do
  read -p "👤 Nome do usuário live (apenas letras minúsculas, sem espaços ou acentos): " live_user
  if ! [[ "$live_user" =~ ^[a-z]+$ ]]; then
    echo "⚠️ O nome deve conter apenas letras minúsculas, sem números, espaços ou acentos."
  elif getent passwd "$live_user" > /dev/null; then
    echo "⚠️ O usuário '$live_user' já existe no sistema. Escolha outro nome."
  elif grep -wq "$live_user" <<< "$RESERVADOS"; then
    echo "⚠️ '$live_user' é um nome reservado. Escolha outro."
  else
    break
  fi
done

read -s -p "🔑 Senha do root: " root_pass
echo ""
read -s -p "🔐 Senha do usuário '$live_user': " live_pass
echo ""

progresso "Corrigindo pacotes quebrados"
apt --fix-broken install -y

progresso "Instalando dependências atualizadas"
apt update
apt install -y \
  squashfs-tools xorriso grub-pc-bin grub-efi-amd64-bin isolinux syslinux syslinux-utils \
  live-boot live-config debootstrap distro-info pv inxi dumpet \
  libgtk2.0-0 libtinfo6 python3-apt calamares calamares-extensions calamares-extensions-data calamares-settings-debian syslinux-common locales console-setup keyboard-configuration --no-install-recommends

progresso "Removendo e recriando a pasta de trabalho"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR/iso/live"

progresso "Copiando sistema base (excluindo diretórios sensíveis)"
rsync -aAX \
  --exclude=/home/$(logname) --exclude=/proc --exclude=/tmp --exclude=/mnt \
  --exclude=/dev --exclude=/run --exclude=/sys --exclude="$WORKDIR" / "$WORKDIR/filesystem"

progresso "Criando usuário live '$live_user' com senha e permissões"
mkdir -p "$WORKDIR/filesystem"/{dev,proc,sys,run,tmp}
chmod 1777 "$WORKDIR/filesystem/tmp"

mount --bind /dev "$WORKDIR/filesystem/dev"
mount --bind /proc "$WORKDIR/filesystem/proc"
mount --bind /sys "$WORKDIR/filesystem/sys"
mount --bind /run "$WORKDIR/filesystem/run"

chroot "$WORKDIR/filesystem" useradd -m "$live_user"
echo "$live_user:$live_pass" | chroot "$WORKDIR/filesystem" chpasswd
chroot "$WORKDIR/filesystem" usermod -aG sudo "$live_user"
echo "root:$root_pass" | chroot "$WORKDIR/filesystem" chpasswd

echo "$live_user ALL=(ALL) NOPASSWD:ALL" > "$WORKDIR/filesystem/etc/sudoers.d/99_$live_user"
chmod 0440 "$WORKDIR/filesystem/etc/sudoers.d/99_$live_user"

progresso "Configurando idioma pt_BR.UTF-8 e teclado br-abnt2"
echo 'pt_BR.UTF-8 UTF-8' > "$WORKDIR/filesystem/etc/locale.gen"
chroot "$WORKDIR/filesystem" locale-gen

echo 'LANG=pt_BR.UTF-8' > "$WORKDIR/filesystem/etc/default/locale"
echo 'LANGUAGE=pt_BR' >> "$WORKDIR/filesystem/etc/default/locale"
echo 'KEYMAP=br-abnt2' > "$WORKDIR/filesystem/etc/vconsole.conf"
echo 'XKBLAYOUT="br"' > "$WORKDIR/filesystem/etc/default/keyboard"
echo 'XKBVARIANT="abnt2"' >> "$WORKDIR/filesystem/etc/default/keyboard"

progresso "Configurando login automático no TTY1"
mkdir -p "$WORKDIR/filesystem/etc/systemd/system/getty@tty1.service.d"
cat <<EOF > "$WORKDIR/filesystem/etc/systemd/system/getty@tty1.service.d/override.conf"
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin $live_user --noclear %I \$TERM
EOF

echo 'Acquire::Languages "none";' > "$WORKDIR/filesystem/etc/apt/apt.conf.d/99disable-translations"

cat <<EOF > "$WORKDIR/filesystem/etc/fstab"
/dev/loop0 / ext4 defaults 0 0
tmpfs /tmp tmpfs nosuid,nodev 0 0
EOF

progresso "Instalando Calamares e regenerando initramfs no chroot"
chroot "$WORKDIR/filesystem" apt update
chroot "$WORKDIR/filesystem" apt install -y calamares live-boot live-config grub-common os-prober --no-install-recommends  # ✅ inclui pacotes necessários para GRUB

KERNEL_VERSION=$(chroot "$WORKDIR/filesystem" sh -c "cd /boot && ls vmlinuz-* 2>/dev/null | sed 's/vmlinuz-//' | sort | tail -n1")
if [[ -n "$KERNEL_VERSION" ]]; then
  chroot "$WORKDIR/filesystem" update-initramfs -u -k "$KERNEL_VERSION"
else
  echo "⚠️ Kernel não encontrado em /boot para gerar initramfs."
fi

progresso "Desmontando pseudo sistemas"
for target in dev proc sys run; do
  mountpoint -q "$WORKDIR/filesystem/$target" && umount -lf "$WORKDIR/filesystem/$target"
done

progresso "Compactando sistema com SquashFS (incluindo /boot)"  # 🔧 ajuste aqui
[ -d "$WORKDIR/filesystem/boot" ] || mkdir -p "$WORKDIR/filesystem/boot"  # ✅ garante existência
mksquashfs "$WORKDIR/filesystem" "$WORKDIR/iso/live/filesystem.squashfs"  # ✅ remove exclusão do boot

progresso "Montando estrutura da ISO e copiando arquivos de boot"
KERNEL=$(basename $(ls -1 "$WORKDIR/filesystem/boot/vmlinuz-"* | sort | tail -n1))
INITRD=$(basename $(ls -1 "$WORKDIR/filesystem/boot/initrd.img-"* | sort | tail -n1))

cp "$WORKDIR/filesystem/boot/$KERNEL" "$WORKDIR/iso/live/vmlinuz"
cp "$WORKDIR/filesystem/boot/$INITRD" "$WORKDIR/iso/live/initrd"

mkdir -p "$WORKDIR/iso/isolinux"
cp /usr/lib/ISOLINUX/isolinux.bin "$WORKDIR/iso/isolinux/"
cp /usr/lib/syslinux/modules/bios/ldlinux.c32 "$WORKDIR/iso/isolinux/"
cp /usr/lib/syslinux/modules/bios/menu.c32 "$WORKDIR/iso/isolinux/"
cp /usr/lib/syslinux/modules/bios/libutil.c32 "$WORKDIR/iso/isolinux/"

cat <<EOF > "$WORKDIR/iso/isolinux/isolinux.cfg"
UI menu.c32
PROMPT 0
TIMEOUT 50
DEFAULT live

LABEL live
  SAY Iniciando sistema live...
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd boot=live username=$live_user hostname=$system_name components quiet splash
EOF

mkdir -p "$WORKDIR/iso/EFI/BOOT"
cp /usr/lib/grub/x86_64-efi/monolithic/grubx64.efi "$WORKDIR/iso/EFI/BOOT/bootx64.efi"

cat <<EOF > "$WORKDIR/iso/EFI/BOOT/grub.cfg"
search --set=root --file /live/vmlinuz
set default=0
set timeout=5

menuentry "Iniciar $system_name (UEFI)" {
    linux /live/vmlinuz boot=live username=$live_user hostname=$system_name components quiet splash
    initrd /live/initrd
}
EOF

progresso "Gerando imagem ISO '$iso_name.iso' com suporte a BIOS e UEFI"
xorriso -as mkisofs \
  -iso-level 3 \
  -o "$WORKDIR/$iso_name.iso" \
  -b isolinux/isolinux.bin \
  -c isolinux/boot.cat \
  -no-emul-boot -boot-load-size 4 -boot-info-table \
  -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
  -eltorito-alt-boot \
  -e EFI/BOOT/bootx64.efi -no-emul-boot \
  -isohybrid-gpt-basdat \
  "$WORKDIR/iso"

if [ $? -eq 0 ]; then
  echo "✅ [$STEP/$TOTAL] ISO criada com sucesso: $WORKDIR/$iso_name.iso"
  chmod 666 "$WORKDIR/$iso_name.iso"
else
  echo "❌ [$STEP/$TOTAL] Falha ao gerar a ISO. Verifique os arquivos de boot e o tamanho do sistema."
  exit 1
fi
STEP=$((STEP+1))

read -p "📤 [$STEP/$TOTAL] Deseja copiar a ISO para /home/$(logname)? [s/n] " resposta
if [[ "$resposta" =~ ^[Ss]$ ]]; then
  cp "$WORKDIR/$iso_name.iso" "/home/$(logname)/" && \
  echo "✅ ISO copiada para /home/$(logname)/"
else
  echo "ℹ️ ISO permanece em: $WORKDIR"
fi

echo "Log da remasterização salvo em: $LOGFILE"
