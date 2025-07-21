#!/bin/bash

SOURCE="/home/casa/.config/dconf/user"

# Verifica se o arquivo existe
if [ ! -f "\$SOURCE" ]; then
  echo "\u274c Arquivo \$SOURCE n\Uffffffffencontrado."
  exit 1
fi

echo "\U0001f527 Copiando para /etc/skel..."
install -Dm600 "\$SOURCE" /etc/skel/.config/dconf/user

echo "\U0001f501 Aplicando para usu\Uffffffffos existentes..."
for dir in /home/*; do
  [ -d "\$dir" ] || continue
  USER="\$(basename "\$dir")"
  install -Dm600 "\$SOURCE" "\$dir/.config/dconf/user"
  chown "\$USER:\$USER" "\$dir/.config/dconf/user"
done

echo "\u2705 Configura\Uffffffffs aplicadas com sucesso."
