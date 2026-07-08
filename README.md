# 🔄 Replicación MySQL en Anillo Multi-Master con Docker (6 Nodos)

Sistema de bases de datos MySQL con **Topología en Anillo (Ring Replication)** completamente dockerizado y distribuido en **6 computadoras físicas** dentro de la misma red local (LAN). Cada nodo funciona simultáneamente como **Maestro y Esclavo**, utilizando **GTID** para identificación global de transacciones.

## 📐 Arquitectura

```
              ┌──────────┐
              │   PC1    │◄─────────────────────────┐
              │ sid=1    │                           │
              │ off=1    │                           │
              └────┬─────┘                           │
                   │ replica de                      │ replica de
                   ▼                                 │
              ┌──────────┐                      ┌──────────┐
              │   PC2    │                      │   PC6    │
              │ sid=2    │                      │ sid=6    │
              │ off=2    │                      │ off=6    │
              └────┬─────┘                      └────▲─────┘
                   │ replica de                      │ replica de
                   ▼                                 │
              ┌──────────┐                      ┌──────────┐
              │   PC3    │                      │   PC5    │
              │ sid=3    │                      │ sid=5    │
              │ off=3    │                      │ off=5    │
              └────┬─────┘                      └────▲─────┘
                   │ replica de                      │ replica de
                   ▼                                 │
              ┌──────────┐                      ┌──────────┐
              │   PC4    │─────────────────────▶│   PC5    │
              │ sid=4    │    replica de         │          │
              │ off=4    │                      │          │
              └──────────┘                      └──────────┘
```

**Flujo del anillo:** PC1 → PC2 → PC3 → PC4 → PC5 → PC6 → PC1

Un INSERT en cualquier nodo viaja por todo el anillo y se detiene automáticamente al regresar al nodo de origen (GTID previene loops infinitos).

---

## 📁 Estructura del Proyecto

```
MASTERS/
├── .env.example                    # Template de variables (IPs + credenciales)
├── .env                            # Variables reales (NO se versiona)
├── docker-compose-pc1.yml          # Compose para PC1 (con MYSQL_DATABASE)
├── docker-compose-pc2.yml          # Compose para PC2
├── docker-compose-pc3.yml          # Compose para PC3
├── docker-compose-pc4.yml          # Compose para PC4
├── docker-compose-pc5.yml          # Compose para PC5
├── docker-compose-pc6.yml          # Compose para PC6
├── setup-ring-replication.sh       # Script para formar el anillo
├── mysql-node1/
│   ├── my.cnf                      # server-id=1, offset=1
│   └── init.sql                    # BD + tablas + usuarios (ÚNICO nodo)
├── mysql-node2/
│   ├── my.cnf                      # server-id=2, offset=2
│   └── init.sql                    # Solo usuarios
├── mysql-node3/
│   ├── my.cnf                      # server-id=3, offset=3
│   └── init.sql                    # Solo usuarios
├── mysql-node4/
│   ├── my.cnf                      # server-id=4, offset=4
│   └── init.sql                    # Solo usuarios
├── mysql-node5/
│   ├── my.cnf                      # server-id=5, offset=5
│   └── init.sql                    # Solo usuarios
├── mysql-node6/
│   ├── my.cnf                      # server-id=6, offset=6
│   └── init.sql                    # Solo usuarios
└── README.md
```

---

## 🚀 Inicio Rápido

### Prerrequisitos

- **Docker** y **Docker Compose** instalados en las 6 PCs.
- **mysql-client** instalado en la máquina desde donde ejecutarás el script.
- Las 6 PCs deben estar en la **misma red LAN** con conectividad entre sí.
- Puerto **3306** abierto en el firewall de cada PC.

### Paso 1: Clonar el proyecto en las 6 PCs

```bash
# En cada PC, clonar el repositorio
git clone <URL_DEL_REPOSITORIO> MASTERS
cd MASTERS
```

### Paso 2: Configurar las IPs

```bash
# En cada PC, copiar el template y ajustar las IPs
cp .env.example .env
nano .env
```

Editar las IPs para que coincidan con tu red LAN:
```env
NODE1_IP=192.168.1.101    # IP real de PC1
NODE2_IP=192.168.1.102    # IP real de PC2
NODE3_IP=192.168.1.103    # IP real de PC3
NODE4_IP=192.168.1.104    # IP real de PC4
NODE5_IP=192.168.1.105    # IP real de PC5
NODE6_IP=192.168.1.106    # IP real de PC6
```

> ⚠️ **El archivo `.env` debe ser IDÉNTICO en las 6 PCs** (mismas IPs, mismas credenciales).

### Paso 3: Levantar contenedores (en orden)

Levantar **primero PC1**, esperar 30 segundos, luego PC2-PC6:

```bash
# En PC1 (PRIMERO — inicializa la BD)
sudo docker compose -f docker-compose-pc1.yml up -d

# Esperar ~30 segundos para que init.sql termine

# En PC2
sudo docker compose -f docker-compose-pc2.yml up -d

# En PC3
sudo docker compose -f docker-compose-pc3.yml up -d

# En PC4
sudo docker compose -f docker-compose-pc4.yml up -d

# En PC5
sudo docker compose -f docker-compose-pc5.yml up -d

# En PC6
sudo docker compose -f docker-compose-pc6.yml up -d

```

### Paso 4: Formar el anillo

Ejecutar desde **cualquier máquina** que tenga `mysql-client` y acceso a las 6 IPs:

```bash
chmod +x setup-ring-replication.sh
./setup-ring-replication.sh
```

El script hará automáticamente:
1. ✅ Verificar conectividad a los 6 nodos
2. ✅ Verificar que `ring_db` exista en Nodo 1
3. ✅ Configurar los 6 enlaces de replicación
4. ✅ Iniciar replicación en todos los nodos
5. ✅ Verificar `SHOW REPLICA STATUS`
6. ✅ Test funcional de propagación

### Paso 5: Verificar la replicación

```bash
# Insertar en cualquier nodo (ejemplo: PC3)
mysql -h 192.168.1.103 -P 3306 -uadmin_lan -padmin_secure_pass \
  -e "INSERT INTO ring_db.test_ring (nodo_origen, mensaje) VALUES ('PC3', 'Hola desde PC3');"

# Verificar en otro nodo (ejemplo: PC1)
mysql -h 192.168.1.101 -P 3306 -uadmin_lan -padmin_secure_pass \
  -e "SELECT * FROM ring_db.test_ring;"
```

---

## ⚙️ Configuración Técnica

### Parámetros de `my.cnf`

| Parámetro | Valor | Propósito |
|-----------|-------|-----------|
| `server-id` | 1-6 (único por nodo) | Identificador del servidor en la replicación |
| `gtid_mode=ON` | Todos | Identificadores globales de transacción |
| `enforce_gtid_consistency=ON` | Todos | Garantiza operaciones seguras con GTID |
| `log_slave_updates=ON` | Todos | **Crítico:** re-escribe al binlog los cambios recibidos por replicación, permitiendo la propagación por el anillo |
| `binlog_format=ROW` | Todos | Formato de replicación más seguro y determinista |
| `auto_increment_increment=6` | Todos | Distribuye los IDs auto-incrementales entre 6 nodos |
| `auto_increment_offset=N` | 1-6 | Cada nodo genera IDs con offset distinto para evitar colisiones |
| `relay_log_recovery=ON` | Todos | Recuperación automática del relay log tras crash |
| `replica_net_timeout=60` | Todos | Timeout de red para detección de desconexiones |

### Distribución de Auto-Increment

Con `auto_increment_increment=6` y offsets 1-6:

| Nodo | Offset | IDs generados |
|------|--------|---------------|
| PC1  | 1      | 1, 7, 13, 19, 25, ... |
| PC2  | 2      | 2, 8, 14, 20, 26, ... |
| PC3  | 3      | 3, 9, 15, 21, 27, ... |
| PC4  | 4      | 4, 10, 16, 22, 28, ... |
| PC5  | 5      | 5, 11, 17, 23, 29, ... |
| PC6  | 6      | 6, 12, 18, 24, 30, ... |

### Prevención de Errores GTID

- **`init.sql` de Nodo 1:** Crea la BD `ring_db`, tablas y datos iniciales. Estas sentencias generan GTIDs y se replican.
- **`init.sql` de Nodos 2-6:** Solo crean usuarios (`replicator` + `admin_lan`) con `sql_log_bin=0`, sin generar GTIDs.
- **`docker-compose-pc2.yml` a `pc6.yml`:** NO definen `MYSQL_DATABASE`, evitando que Docker cree la BD automáticamente (lo cual generaría GTIDs conflictivos).

### Usuarios MySQL

| Usuario | Host | Propósito | Permisos |
|---------|------|-----------|----------|
| `root` | `localhost` | Administración local (dentro del contenedor) | ALL PRIVILEGES |
| `admin_lan` | `%` | Administración remota vía LAN | ALL PRIVILEGES + GRANT OPTION |
| `replicator` | `%` | Replicación entre nodos | REPLICATION SLAVE |

---

## 🔥 Configuración de Firewall

Abrir el puerto 3306 solo para la subred LAN en **cada PC**:

### Con `ufw` (Ubuntu/Debian)

```bash
# Permitir MySQL solo desde la LAN
sudo ufw allow from 192.168.1.0/24 to any port 3306 proto tcp

# Verificar
sudo ufw status
```

### Con `firewalld` (CentOS/RHEL/Fedora)

```bash
sudo firewall-cmd --permanent --add-rich-rule='rule family="ipv4" source address="192.168.1.0/24" port protocol="tcp" port="3306" accept'
sudo firewall-cmd --reload
```

### Con `iptables`

```bash
sudo iptables -A INPUT -p tcp -s 192.168.1.0/24 --dport 3306 -j ACCEPT
sudo iptables -A INPUT -p tcp --dport 3306 -j DROP
```

---

## 🔍 Comandos de Monitoreo

### Verificar estado de replicación en un nodo

```bash
mysql -h <IP_NODO> -P 3306 -uadmin_lan -padmin_secure_pass \
  -e "SHOW REPLICA STATUS\G"
```

Campos clave:
- `Replica_IO_Running: Yes` → Conexión activa con el nodo fuente
- `Replica_SQL_Running: Yes` → Aplicando transacciones correctamente
- `Seconds_Behind_Source: 0` → Sincronizado

### Ver GTIDs ejecutados en un nodo

```bash
mysql -h <IP_NODO> -P 3306 -uadmin_lan -padmin_secure_pass \
  -e "SELECT @@global.gtid_executed\G"
```

### Verificar datos de prueba

```bash
mysql -h <IP_NODO> -P 3306 -uadmin_lan -padmin_secure_pass \
  -e "SELECT * FROM ring_db.test_ring ORDER BY id;"
```

### Verificar variables de replicación

```bash
mysql -h <IP_NODO> -P 3306 -uadmin_lan -padmin_secure_pass \
  -e "SHOW VARIABLES LIKE 'server_id'; SHOW VARIABLES LIKE 'auto_increment%'; SHOW VARIABLES LIKE 'gtid_mode';"
```

---

## 🛠️ Solución de Problemas

### `Replica_IO_Running: No`

```bash
# Verificar conectividad de red
mysql -h <IP_FUENTE> -P 3306 -ureplicator -preplpassword -e "SELECT 1;"

# Verificar firewall
sudo ufw status | grep 3306

# Revisar logs del contenedor
sudo docker logs mysql-nodeX --tail 50
```

### `Replica_SQL_Running: No`

```bash
# Ver el error exacto
mysql -h <IP_NODO> -P 3306 -uadmin_lan -padmin_secure_pass \
  -e "SHOW REPLICA STATUS\G" | grep -E "Last.*Error"

# Si es error de dato duplicado, puedes saltar la transacción:
# ⚠️ PELIGRO: Solo si entiendes la implicación
mysql -h <IP_NODO> -P 3306 -uadmin_lan -padmin_secure_pass \
  -e "SET GLOBAL sql_slave_skip_counter = 1; START REPLICA;"
```

### Reconstruir un nodo desde cero

```bash
# En la PC del nodo afectado
sudo docker compose -f docker-compose-pcX.yml down -v
sudo docker compose -f docker-compose-pcX.yml up -d

# Esperar inicio, luego reconectar al anillo
# Solo necesitas reconfigurar ESE nodo:
mysql -h <IP_NODO> -P 3306 -uadmin_lan -padmin_secure_pass -e "
    CHANGE REPLICATION SOURCE TO
        SOURCE_HOST='<IP_NODO_ANTERIOR>',
        SOURCE_PORT=3306,
        SOURCE_USER='replicator',
        SOURCE_PASSWORD='replpassword',
        SOURCE_AUTO_POSITION=1,
        GET_SOURCE_PUBLIC_KEY=1;
    START REPLICA;
"
```

### Reconstruir todo el anillo

```bash
# 1. Detener todos los contenedores (en cada PC)
sudo docker compose -f docker-compose-pcX.yml down -v

# 2. Levantar PC1 primero, esperar 30s, luego PC2-PC6
# 3. Ejecutar setup-ring-replication.sh
```

---

## 📋 Tabla de Conexión

| Nodo | IP (ejemplo) | Puerto | Container |
|------|-------------|--------|-----------|
| PC1  | 192.168.1.101 | 3306 | mysql-node1 |
| PC2  | 192.168.1.102 | 3306 | mysql-node2 |
| PC3  | 192.168.1.103 | 3306 | mysql-node3 |
| PC4  | 192.168.1.104 | 3306 | mysql-node4 |
| PC5  | 192.168.1.105 | 3306 | mysql-node5 |
| PC6  | 192.168.1.106 | 3306 | mysql-node6 |

**Conexión desde el host:**
```bash
mysql -h 192.168.1.101 -P 3306 -uadmin_lan -padmin_secure_pass
```

---

## ⚠️ Consideraciones Importantes

1. **Escrituras simultáneas en el mismo registro:** Evitar que dos nodos modifiquen la misma fila al mismo tiempo. El anillo NO resuelve conflictos de escritura automáticamente.

2. **Latencia del anillo:** Un cambio en PC1 debe viajar por 5 nodos antes de llegar a PC6. En una LAN, esto suele ser milisegundos, pero considéralo para aplicaciones críticas.

3. **Nodo caído:** Si un nodo se cae, el anillo se **rompe** en ese punto. Los nodos que dependen de él dejarán de recibir actualizaciones. Al restaurar el nodo, la replicación GTID se reconecta automáticamente.

4. **Backups:** Se recomienda hacer backups en al menos un nodo:
   ```bash
   mysqldump -h <IP> -P 3306 -uadmin_lan -padmin_secure_pass \
     --all-databases --single-transaction --routines --triggers \
     --no-tablespaces | gzip > backup_$(date +%Y%m%d_%H%M%S).sql.gz
   ```
