#!/bin/bash

# ============================================================
#  setup-ring-replication.sh
#  Topología en Anillo Multi-Master con 6 Nodos (GTID)
#
#  Forma el anillo: PC1 → PC2 → PC3 → PC4 → PC5 → PC6 → PC1
#  Cada nodo replica del nodo anterior en el anillo.
#
#  Prerrequisitos:
#    - Los 6 contenedores deben estar corriendo en sus PCs.
#    - El archivo .env debe existir con las 6 IPs configuradas.
#    - mysql-client instalado en la máquina que ejecuta este script.
#
#  Uso: ./setup-ring-replication.sh
# ============================================================

set -euo pipefail

# --- Colores para salida ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # Sin color

# --- Cargar variables de entorno ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

if [ ! -f "$ENV_FILE" ]; then
    echo -e "${RED}❌ Error: No se encontró el archivo .env en ${SCRIPT_DIR}${NC}"
    echo -e "${YELLOW}   Copia .env.example a .env y configura las IPs de tu LAN.${NC}"
    exit 1
fi

# shellcheck source=/dev/null
source "$ENV_FILE"

# --- Validar que todas las IPs estén definidas ---
REQUIRED_VARS=(NODE1_IP NODE2_IP NODE3_IP NODE4_IP NODE5_IP NODE6_IP MYSQL_PORT ADMIN_USER ADMIN_PASSWORD REPL_USER REPL_PASSWORD)
for var in "${REQUIRED_VARS[@]}"; do
    if [ -z "${!var:-}" ]; then
        echo -e "${RED}❌ Error: La variable ${var} no está definida en .env${NC}"
        exit 1
    fi
done

# --- Definir el anillo ---
# Formato: NODO_IPS[índice]=IP_del_nodo
# Formato: RING_SOURCE[índice]=IP_de_quien_replica (nodo anterior en el anillo)
declare -a NODO_IPS=("$NODE1_IP" "$NODE2_IP" "$NODE3_IP" "$NODE4_IP" "$NODE5_IP" "$NODE6_IP")
declare -a RING_SOURCE=("$NODE6_IP" "$NODE1_IP" "$NODE2_IP" "$NODE3_IP" "$NODE4_IP" "$NODE5_IP")
# PC1 replica de PC6 (cierra el anillo)
# PC2 replica de PC1
# PC3 replica de PC2
# PC4 replica de PC3
# PC5 replica de PC4
# PC6 replica de PC5

# Puertos por nodo: todos usan MYSQL_PORT
declare -a NODO_PORTS=("$MYSQL_PORT" "$MYSQL_PORT" "$MYSQL_PORT" "$MYSQL_PORT" "$MYSQL_PORT" "$MYSQL_PORT")
# Puertos del source (nodo anterior en el anillo) para cada réplica
declare -a RING_SOURCE_PORTS=("$MYSQL_PORT" "$MYSQL_PORT" "$MYSQL_PORT" "$MYSQL_PORT" "$MYSQL_PORT" "$MYSQL_PORT")

# --- Función: ejecutar MySQL en un nodo remoto ---
exec_mysql() {
    local host="$1"
    local port="$2"
    local sql="$3"
    mysql -h "$host" -P "$port" -u"$ADMIN_USER" -p"$ADMIN_PASSWORD" -e "$sql" 2>/dev/null
}

# --- Función: ejecutar MySQL y capturar salida ---
exec_mysql_raw() {
    local host="$1"
    local port="$2"
    local sql="$3"
    mysql -h "$host" -P "$port" -u"$ADMIN_USER" -p"$ADMIN_PASSWORD" -N -e "$sql" 2>/dev/null
}

# ============================================================
#  FASE 1: Verificar conectividad a los 6 nodos
# ============================================================
echo -e "${CYAN}============================================================${NC}"
echo -e "${CYAN}  🔗 Topología en Anillo — Configuración de Replicación${NC}"
echo -e "${CYAN}  PC1 → PC2 → PC3 → PC4 → PC5 → PC6 → PC1${NC}"
echo -e "${CYAN}============================================================${NC}"
echo ""

echo -e "${YELLOW}📡 Fase 1: Verificando conectividad a los 6 nodos...${NC}"

for i in {0..5}; do
    NODE_NUM=$((i + 1))
    IP="${NODO_IPS[$i]}"
    N_PORT="${NODO_PORTS[$i]}"
    echo -n "   Nodo $NODE_NUM ($IP:$N_PORT)... "

    RETRIES=0
    MAX_RETRIES=30
    until mysqladmin ping -h "$IP" -P "$N_PORT" -u"$ADMIN_USER" -p"$ADMIN_PASSWORD" --silent 2>/dev/null; do
        RETRIES=$((RETRIES + 1))
        if [ $RETRIES -ge $MAX_RETRIES ]; then
            echo -e "${RED}❌ TIMEOUT después de ${MAX_RETRIES} intentos${NC}"
            echo -e "${RED}   Verifica que el contenedor en PC${NODE_NUM} esté corriendo.${NC}"
            exit 1
        fi
        sleep 2
    done
    echo -e "${GREEN}✅ Conectado${NC}"
done

echo ""

# ============================================================
#  FASE 2: Verificar que la BD de Nodo 1 esté lista
# ============================================================
echo -e "${YELLOW}🗄️  Fase 2: Verificando que ring_db exista en Nodo 1...${NC}"

RETRIES=0
MAX_RETRIES=20
until exec_mysql_raw "${NODO_IPS[0]}" "${NODO_PORTS[0]}" "SELECT SCHEMA_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='ring_db';" | grep -q "ring_db"; do
    RETRIES=$((RETRIES + 1))
    if [ $RETRIES -ge $MAX_RETRIES ]; then
        echo -e "${RED}❌ La base de datos ring_db no existe en Nodo 1.${NC}"
        echo -e "${RED}   Verifica que init.sql se haya ejecutado correctamente.${NC}"
        exit 1
    fi
    sleep 2
done
echo -e "   ring_db en Nodo 1: ${GREEN}✅ Lista${NC}"
echo ""

# ============================================================
#  FASE 3: Detener cualquier replicación existente
# ============================================================
echo -e "${YELLOW}🛑 Fase 3: Deteniendo replicación existente en todos los nodos...${NC}"

for i in {0..5}; do
    NODE_NUM=$((i + 1))
    IP="${NODO_IPS[$i]}"
    N_PORT="${NODO_PORTS[$i]}"
    echo -n "   Nodo $NODE_NUM... "
    exec_mysql "$IP" "$N_PORT" "STOP REPLICA; RESET REPLICA ALL;" 2>/dev/null || true
    echo -e "${GREEN}✅ Limpio${NC}"
done

echo ""

# ============================================================
#  FASE 4: Configurar el anillo de replicación
# ============================================================
echo -e "${YELLOW}🔄 Fase 4: Configurando enlaces de replicación del anillo...${NC}"
echo ""

for i in {0..5}; do
    NODE_NUM=$((i + 1))
    REPLICA_IP="${NODO_IPS[$i]}"
    REPLICA_PORT="${NODO_PORTS[$i]}"
    SOURCE_IP="${RING_SOURCE[$i]}"
    SOURCE_PORT="${RING_SOURCE_PORTS[$i]}"
    SOURCE_NUM=$(( (i + 5) % 6 + 1 ))  # Nodo anterior en el anillo

    echo -e "   ${CYAN}Nodo $NODE_NUM ($REPLICA_IP:$REPLICA_PORT) ← replica de ← Nodo $SOURCE_NUM ($SOURCE_IP:$SOURCE_PORT)${NC}"

    exec_mysql "$REPLICA_IP" "$REPLICA_PORT" "
        CHANGE REPLICATION SOURCE TO
            SOURCE_HOST='${SOURCE_IP}',
            SOURCE_PORT=${SOURCE_PORT},
            SOURCE_USER='${REPL_USER}',
            SOURCE_PASSWORD='${REPL_PASSWORD}',
            SOURCE_AUTO_POSITION=1,
            GET_SOURCE_PUBLIC_KEY=1;
    "

    if [ $? -eq 0 ]; then
        echo -e "   ${GREEN}✅ Enlace configurado${NC}"
    else
        echo -e "   ${RED}❌ Error configurando enlace${NC}"
        exit 1
    fi
done

echo ""

# ============================================================
#  FASE 5: Iniciar replicación en todos los nodos
# ============================================================
echo -e "${YELLOW}▶️  Fase 5: Iniciando replicación en todos los nodos...${NC}"

for i in {0..5}; do
    NODE_NUM=$((i + 1))
    IP="${NODO_IPS[$i]}"
    N_PORT="${NODO_PORTS[$i]}"
    echo -n "   Nodo $NODE_NUM... "
    exec_mysql "$IP" "$N_PORT" "START REPLICA;"
    echo -e "${GREEN}✅ Replicación iniciada${NC}"
done

echo ""

# --- Esperar unos segundos para que los hilos se estabilicen ---
echo -e "${YELLOW}⏳ Esperando 10 segundos para estabilización...${NC}"
sleep 10
echo ""

# ============================================================
#  FASE 6: Verificar estado de replicación en cada nodo
# ============================================================
echo -e "${YELLOW}🔍 Fase 6: Verificando estado de replicación...${NC}"
echo ""

ALL_OK=true

for i in {0..5}; do
    NODE_NUM=$((i + 1))
    IP="${NODO_IPS[$i]}"
    N_PORT="${NODO_PORTS[$i]}"
    SOURCE_NUM=$(( (i + 5) % 6 + 1 ))

    echo -e "${CYAN}--- Nodo $NODE_NUM ($IP:$N_PORT) — replica de Nodo $SOURCE_NUM ---${NC}"

    STATUS=$(exec_mysql_raw "$IP" "$N_PORT" "SHOW REPLICA STATUS\G" 2>/dev/null)

    IO_RUNNING=$(echo "$STATUS" | grep "Replica_IO_Running:" | awk '{print $2}')
    SQL_RUNNING=$(echo "$STATUS" | grep "Replica_SQL_Running:" | awk '{print $2}' | head -1)
    LAST_ERROR=$(echo "$STATUS" | grep "Last_Error:" | head -1 | sed 's/.*Last_Error: //')
    LAST_IO_ERROR=$(echo "$STATUS" | grep "Last_IO_Error:" | sed 's/.*Last_IO_Error: //')
    SECONDS_BEHIND=$(echo "$STATUS" | grep "Seconds_Behind_Source:" | awk '{print $2}')

    # Mostrar estado con colores
    if [ "$IO_RUNNING" = "Yes" ]; then
        echo -e "   Replica_IO_Running:  ${GREEN}${IO_RUNNING}${NC}"
    else
        echo -e "   Replica_IO_Running:  ${RED}${IO_RUNNING:-N/A}${NC}"
        ALL_OK=false
    fi

    if [ "$SQL_RUNNING" = "Yes" ]; then
        echo -e "   Replica_SQL_Running: ${GREEN}${SQL_RUNNING}${NC}"
    else
        echo -e "   Replica_SQL_Running: ${RED}${SQL_RUNNING:-N/A}${NC}"
        ALL_OK=false
    fi

    echo -e "   Seconds_Behind:     ${SECONDS_BEHIND:-N/A}"

    if [ -n "$LAST_ERROR" ] && [ "$LAST_ERROR" != " " ]; then
        echo -e "   ${RED}Last_Error: ${LAST_ERROR}${NC}"
    fi
    if [ -n "$LAST_IO_ERROR" ] && [ "$LAST_IO_ERROR" != " " ]; then
        echo -e "   ${RED}Last_IO_Error: ${LAST_IO_ERROR}${NC}"
    fi

    echo ""
done

# ============================================================
#  FASE 7: Test funcional de propagación por el anillo
# ============================================================
echo -e "${YELLOW}🧪 Fase 7: Test funcional — propagación por el anillo...${NC}"
echo ""

# Insertar un registro de prueba en Nodo 1
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
echo -e "   Insertando registro de prueba en Nodo 1..."
exec_mysql "${NODO_IPS[0]}" "${NODO_PORTS[0]}" "
    INSERT INTO ring_db.test_ring (nodo_origen, mensaje)
    VALUES ('PC1', 'Test de anillo — ${TIMESTAMP}');
"

# Esperar propagación
echo -e "   ⏳ Esperando 15 segundos para propagación completa..."
sleep 15

# Verificar en cada nodo
echo ""
for i in {0..5}; do
    NODE_NUM=$((i + 1))
    IP="${NODO_IPS[$i]}"
    N_PORT="${NODO_PORTS[$i]}"
    echo -n "   Nodo $NODE_NUM ($IP:$N_PORT): "

    RESULT=$(exec_mysql_raw "$IP" "$N_PORT" "SELECT COUNT(*) FROM ring_db.test_ring WHERE mensaje LIKE 'Test de anillo%' AND nodo_origen='PC1';" 2>/dev/null)

    if [ -n "$RESULT" ] && [ "$RESULT" -gt 0 ] 2>/dev/null; then
        echo -e "${GREEN}✅ Registro encontrado ($RESULT coincidencias)${NC}"
    else
        echo -e "${RED}❌ Registro NO encontrado${NC}"
        ALL_OK=false
    fi
done

echo ""

# ============================================================
#  RESUMEN FINAL
# ============================================================
echo -e "${CYAN}============================================================${NC}"
if [ "$ALL_OK" = true ]; then
    echo -e "${GREEN}  ✅ ¡ANILLO DE REPLICACIÓN CONFIGURADO EXITOSAMENTE!${NC}"
    echo -e ""
    echo -e "  Topología activa:"
    echo -e "  ${CYAN}PC1 (${NODO_IPS[0]}) → PC2 (${NODO_IPS[1]}) → PC3 (${NODO_IPS[2]})${NC}"
    echo -e "  ${CYAN}→ PC4 (${NODO_IPS[3]}) → PC5 (${NODO_IPS[4]}) → PC6 (${NODO_IPS[5]}) → PC1${NC}"
else
    echo -e "${RED}  ⚠️  ANILLO CONFIGURADO CON ADVERTENCIAS${NC}"
    echo -e "${YELLOW}  Revisa los errores anteriores y verifica:${NC}"
    echo -e "${YELLOW}    1. Que los 6 contenedores estén corriendo${NC}"
    echo -e "${YELLOW}    2. Que las IPs en .env sean correctas${NC}"
    echo -e "${YELLOW}    3. Que el firewall permita el puerto ${MYSQL_PORT}${NC}"
    echo -e "${YELLOW}    4. Ejecuta en cada nodo: SHOW REPLICA STATUS\\G${NC}"
fi
echo -e "${CYAN}============================================================${NC}"
echo ""
echo -e "Comandos útiles para monitoreo:"
echo -e "  ${CYAN}mysql -h <IP> -P <PUERTO> -u$ADMIN_USER -p$ADMIN_PASSWORD -e 'SHOW REPLICA STATUS\\G'${NC}"
echo -e "  ${CYAN}mysql -h <IP> -P <PUERTO> -u$ADMIN_USER -p$ADMIN_PASSWORD -e 'SELECT * FROM ring_db.test_ring;'${NC}"
