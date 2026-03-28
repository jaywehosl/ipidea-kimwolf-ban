#!/bin/bash

# Проверка на root
if [[ $EUID -ne 0 ]]; then
   echo "Этот скрипт нужно запускать от root (через sudo)"
   exit 1
fi

echo "--- Начинаю установку 'Ядерного бана' для Leaseweb ---"

# 1. Установка необходимых пакетов
apt update && apt install ipset iptables-persistent whois curl -y

# 2. Создаем основной скрипт обновления базы IP
cat << 'EOF' > /usr/local/bin/block_leaseweb.sh
#!/bin/bash
# Список ASN Leaseweb
ASNS=("AS16265" "AS60781" "AS28753" "AS30633" "AS38731" "AS49367" "AS51395" "AS50673" "AS59253" "AS133752" "AS134351")

# Создаем сеты, если их нет
ipset create leaseweb_v4 hash:net family inet hashsize 4096 maxelem 65536 2>/dev/null
ipset create leaseweb_v6 hash:net family inet6 hashsize 4096 maxelem 65536 2>/dev/null

echo "Загрузка актуальных IP-диапазонов Leaseweb..."
for ASN in "${ASNS[@]}"; do
    # IPv4
    whois -h whois.radb.net -- "-i origin $ASN" | grep -E '^route:' | awk '{print $2}' | while read -r ip; do
        ipset add leaseweb_v4 $ip -quiet
    done
    # IPv6
    whois -h whois.radb.net -- "-i origin $ASN" | grep -E '^route6:' | awk '{print $2}' | while read -r ip; do
        ipset add leaseweb_v6 $ip -quiet
    done
done

# Сохраняем состояние для автозагрузки
ipset save > /etc/ipset.conf
echo "База IP обновлена и сохранена в /etc/ipset.conf"
EOF

chmod +x /usr/local/bin/block_leaseweb.sh

# 3. Создаем сервис для загрузки ipset ПЕРЕД iptables
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

systemctl daemon-reload
systemctl enable ipset-persistent

# 4. Первый запуск скрипта (собираем IP прямо сейчас)
/usr/local/bin/block_leaseweb.sh

# 5. Настройка правил iptables (Вход, Выход, Прокси/Forward)
echo "Применяю правила блокировки в iptables..."

# Очистка старых правил с этим сетом (чтобы не дублировать)
iptables -D INPUT -m set --match-set leaseweb_v4 src -j DROP 2>/dev/null
iptables -D OUTPUT -m set --match-set leaseweb_v4 dst -j DROP 2>/dev/null
iptables -D FORWARD -m set --match-set leaseweb_v4 src,dst -j DROP 2>/dev/null
ip6tables -D INPUT -m set --match-set leaseweb_v6 src -j DROP 2>/dev/null
ip6tables -D OUTPUT -m set --match-set leaseweb_v6 dst -j DROP 2>/dev/null
ip6tables -D FORWARD -m set --match-set leaseweb_v6 src,dst -j DROP 2>/dev/null

# Добавляем правила в начало цепочек (-I)
iptables -I INPUT -m set --match-set leaseweb_v4 src -j DROP
iptables -I OUTPUT -m set --match-set leaseweb_v4 dst -j DROP
iptables -I FORWARD -m set --match-set leaseweb_v4 src,dst -j DROP

ip6tables -I INPUT -m set --match-set leaseweb_v6 src -j DROP
ip6tables -I OUTPUT -m set --match-set leaseweb_v6 dst -j DROP
ip6tables -I FORWARD -m set --match-set leaseweb_v6 src,dst -j DROP

# 6. Сохраняем iptables намертво
netfilter-persistent save

# 7. Добавляем обновление в Cron (каждый понедельник в 3 утра)
(crontab -l 2>/dev/null | grep -v "block_leaseweb.sh"; echo "0 3 * * 1 /usr/local/bin/block_leaseweb.sh && netfilter-persistent save") | crontab -

echo "--- УСТАНОВКА ЗАВЕРШЕНА ---"
echo "Проверка:"
echo "1. IP в сете: $(ipset list leaseweb_v4 | grep -c '/')"
echo "2. Тест пинга Leaseweb (85.17.70.38):"
ping -c 1 -W 1 85.17.70.38 || echo "ПИНГ ЗАБЛОКИРОВАН (Успех)"
