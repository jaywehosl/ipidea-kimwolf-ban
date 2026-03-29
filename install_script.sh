#!/bin/bash

# Проверка на root
if [[ $EUID -ne 0 ]]; then
   echo "Ошибка! Запустите скрипт с рут правами."
   exit 1
fi

# Отключение интерактивных окон apt
export DEBIAN_FRONTEND=noninteractive

echo -n "1/6 [....] Установка системных пакетов ipset, whois..."
# -qq отключает confirm tab $ service select, >/dev/null убирает остальной текст
apt-get update -y -qq > /dev/null 2>&1
apt-get install -y -qq -o=Dpkg::Use-Pty=0 ipset iptables-persistent whois curl > /dev/null 2>&1
echo -e "\r1/6 [DONE] Пакеты установлены.                         "

echo -n "2/6 [....] Создание скрипта блокировки..."
cat << 'EOF' > /usr/local/bin/block_leaseweb.sh
#!/bin/bash
ASNS=("AS16265" "AS60781" "AS28753" "AS30633" "AS38731" "AS49367" "AS51395" "AS50673" "AS59253" "AS133752" "AS134351")
ipset create leaseweb_v4 hash:net family inet hashsize 4096 maxelem 65536 2>/dev/null
ipset create leaseweb_v6 hash:net family inet6 hashsize 4096 maxelem 65536 2>/dev/null
for ASN in "${ASNS[@]}"; do
    whois -h whois.radb.net -- "-i origin $ASN" | grep -E '^route:' | awk '{print $2}' | while read -r ip; do ipset add leaseweb_v4 $ip -quiet; done
    whois -h whois.radb.net -- "-i origin $ASN" | grep -E '^route6:' | awk '{print $2}' | while read -r ip; do ipset add leaseweb_v6 $ip -quiet; done
done
ipset save > /etc/ipset.conf
EOF
chmod +x /usr/local/bin/block_leaseweb.sh
echo -e "\r2/6 [DONE] Скрипт создан в /usr/local/bin/             "

echo -n "3/6 [....] Настройка автозагрузки ipset..."
cat << 'EOF' > /etc/systemd/system/ipset-persistent.service
[Unit]
Description=Restore ipset sets before iptables
Before=network.target netfilter-persistent.service
ConditionFileNotEmpty=/etc/ipset.conf
[Service]
Type=oneshot
ExecStart=/sbin/ipset restore -file /etc/ipset.conf
ExecStop=/sbin/ipset save -file /etc/ipset.conf
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload > /dev/null 2>&1
systemctl enable ipset-persistent > /dev/null 2>&1
echo -e "\r3/6 [DONE] Автозагрузка настроена.                     "

echo -n "4/6 [....] Загружаю базу ASN Leaseweb..."
/usr/local/bin/block_leaseweb.sh
echo -e "\r4/6 [DONE] База IP успешно загружена                  "

echo -n "5/6 [....] Применение правил iptables..."
iptables -I INPUT -m set --match-set leaseweb_v4 src -j DROP
iptables -I OUTPUT -m set --match-set leaseweb_v4 dst -j DROP
iptables -I FORWARD -m set --match-set leaseweb_v4 src,dst -j DROP
ip6tables -I INPUT -m set --match-set leaseweb_v6 src -j DROP
ip6tables -I OUTPUT -m set --match-set leaseweb_v6 dst -j DROP
ip6tables -I FORWARD -m set --match-set leaseweb_v6 src,dst -j DROP
# Сохраняем тихо
netfilter-persistent save > /dev/null 2>&1
echo -e "\r5/6 [DONE] Фаерволл настроен.                    "

echo -n "6/6 [....] Добавление задачи в Cron..."
(crontab -l 2>/dev/null | grep -v "block_leaseweb.sh"; echo "0 3 * * 1 /usr/local/bin/block_leaseweb.sh && netfilter-persistent save > /dev/null 2>&1") | crontab -
echo -e "\r6/6 [DONE] Еженедельное обновление включено.           "

echo "-------------------------------------------------------"
echo "РЕЗУЛЬТАТ: В базе $(ipset list leaseweb_v4 | grep -c '/') подсетей."
ping -c 1 -W 1 85.17.70.38 > /dev/null 2>&1 || echo "ТЕСТ: IPIDEA/Kimwolf заблокированы."
echo "-------------------------------------------------------"
