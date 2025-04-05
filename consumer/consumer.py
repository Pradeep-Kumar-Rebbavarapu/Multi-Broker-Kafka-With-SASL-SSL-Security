import os
import time
import ssl
import logging
import signal
import threading
import json
import psycopg2
from psycopg2 import pool
from kafka import KafkaConsumer
from kafka.errors import KafkaError

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
)
logger = logging.getLogger('kafka-consumer')

class GracefulKiller:
    kill_now = False
    
    def __init__(self):
        signal.signal(signal.SIGINT, self.exit_gracefully)
        signal.signal(signal.SIGTERM, self.exit_gracefully)
    
    def exit_gracefully(self, *args):
        logger.info("Shutdown signal received")
        self.kill_now = True

class HealthCheck:
    def __init__(self):
        self.health_file = "/app/consumer_healthy"
        
    def mark_healthy(self):
        try:
            with open(self.health_file, 'w') as f:
                f.write('healthy')
        except Exception as e:
            logger.warning(f"Failed to write health check file: {e}")
            
    def mark_unhealthy(self):
        try:
            if os.path.exists(self.health_file):
                os.remove(self.health_file)
        except Exception as e:
            logger.warning(f"Failed to remove health check file: {e}")

class DatabaseManager:
    def __init__(self, db_config):
        self.db_config = db_config
        self.connection_pool = None
        self.reconnect_count = 0
        self.max_reconnect_attempts = 15
        self.init_connection_pool()
    
    def init_connection_pool(self):
        try:
            self.connection_pool = psycopg2.pool.ThreadedConnectionPool(
                minconn=1,
                maxconn=10,
                **self.db_config
            )
            conn = self.connection_pool.getconn()
            if conn:
                logger.info("Successfully connected to TimescaleDB")
                self.connection_pool.putconn(conn)
                self.reconnect_count = 0
                return True
        except Exception as e:
            logger.error(f"Failed to connect to database: {e}")
            if self.connection_pool:
                self.connection_pool.closeall()
                self.connection_pool = None
            return False
    
    def get_connection(self):
        if not self.connection_pool:
            if not self.init_connection_pool():
                if self.reconnect_count >= self.max_reconnect_attempts:
                    logger.critical("Max reconnection attempts reached. Giving up on database connection.")
                    return None
                self.reconnect_count += 1
                wait_time = min(5 * (1.5 ** min(self.reconnect_count, 10)), 300)
                logger.info(f"Waiting {wait_time:.1f} seconds before retrying...")
                time.sleep(wait_time)
                return self.get_connection()
            
        try:
            return self.connection_pool.getconn()
        except Exception as e:
            logger.error(f"Error getting connection from pool: {e}")
            self.connection_pool = None
            return self.get_connection()
    
    def release_connection(self, conn):
        if self.connection_pool and conn:
            try:
                self.connection_pool.putconn(conn)
            except Exception as e:
                logger.error(f"Error returning connection to pool: {e}")
                try:
                    conn.close()
                except:
                    pass
    
    def close_all(self):
        if self.connection_pool:
            try:
                self.connection_pool.closeall()
                logger.info("Closed all database connections")
            except Exception as e:
                logger.error(f"Error closing connection pool: {e}")

class Consumer:
    def __init__(self, bootstrap_servers, topics, group_id, db_config) -> None:
        self.bootstrap_servers = bootstrap_servers
        self.topics = topics
        self.group_id = group_id
        self.consumer = None
        self.connected = False
        self.health_check = HealthCheck()
        self.health_check.mark_unhealthy()
        self.db_manager = DatabaseManager(db_config)
        self.ca_cert = os.environ.get('CA_CERT_PATH')
        self.client_cert = os.environ.get('CLIENT_CERT_PATH')
        self.client_key = os.environ.get('CLIENT_KEY_PATH')
        self.sasl_username = os.environ.get('SASL_USERNAME', 'sa')
        self.sasl_password = os.environ.get('SASL_PASSWORD', '000000')
        self.max_retries = 15
        self.retry_interval = 10
        self.max_reconnect_retries = None
        self.monitor_thread = None
        self.should_monitor = True
        
    def create_ssl_context(self):
        ssl_context = ssl.create_default_context()
        if self.ca_cert and os.path.exists(self.ca_cert):
            logger.info(f"Loading CA certificate from {self.ca_cert}")
            ssl_context.load_verify_locations(self.ca_cert)
            ssl_context.check_hostname = True
            ssl_context.verify_mode = ssl.CERT_REQUIRED
        else:
            logger.warning("CA certificate not found, disabling certificate verification")
            ssl_context.check_hostname = False
            ssl_context.verify_mode = ssl.CERT_NONE
        
        if self.client_cert and self.client_key and os.path.exists(self.client_cert) and os.path.exists(self.client_key):
            logger.info(f"Loading client certificate from {self.client_cert} and key from {self.client_key}")
            ssl_context.load_cert_chain(certfile=self.client_cert, keyfile=self.client_key)
        else:
            logger.warning("Client certificate or key not found")
        
        return ssl_context

    def create_consumer(self):
        """Create a new KafkaConsumer instance"""
        ssl_context = self.create_ssl_context()
        
        logger.info(f"Connecting to bootstrap servers: {self.bootstrap_servers}")
        
        return KafkaConsumer(
            *self.topics,
            bootstrap_servers=self.bootstrap_servers,
            security_protocol="SASL_SSL",
            sasl_mechanism="PLAIN",
            sasl_plain_username=self.sasl_username,
            sasl_plain_password=self.sasl_password,
            ssl_context=ssl_context,
            auto_offset_reset="earliest",
            enable_auto_commit=True,
            group_id=self.group_id,
            key_deserializer=lambda v: v.decode("utf-8") if v else None,
            value_deserializer=lambda v: json.loads(v.decode("utf-8")) if v else None,  # Parse JSON
            api_version_auto_timeout_ms=30000,
            request_timeout_ms=60000,
            session_timeout_ms=30000,
            heartbeat_interval_ms=10000,
            max_poll_interval_ms=300000,
            connections_max_idle_ms=540000,
        )
    
    def connect_with_retry(self):
        """Attempt to connect to Kafka with retries"""
        retries = 0
        max_attempts = self.max_retries if self.connected else self.max_reconnect_retries
        
        while max_attempts is None or retries < max_attempts:
            try:
                if self.consumer:
                    try:
                        self.consumer.close(autocommit=False)
                    except:
                        pass
                
                self.consumer = self.create_consumer()
                logger.info("Testing connection to Kafka...")
                self.consumer.topics()
                logger.info("Successfully connected to Kafka")
                self.connected = True
                self.health_check.mark_healthy()
                return True
            except Exception as e:
                retries += 1
                self.health_check.mark_unhealthy()
                
                if max_attempts is not None and retries >= max_attempts:
                    logger.critical(f"Max retries ({max_attempts}) reached. Could not connect to Kafka.")
                    return False
                
                wait_time = min(self.retry_interval * (1.5 ** min(retries, 10)), 300)
                logger.error(f"Failed to connect to Kafka (Attempt {retries}): {str(e)}")
                logger.info(f"Retrying in {wait_time:.1f} seconds...")
                time.sleep(wait_time)
        
        return False

    def monitor_connection(self):
        """Monitor the Kafka connection and reconnect if necessary"""
        while self.should_monitor:
            try:
                if self.connected and self.consumer:
                    try:
                        self.consumer.topics()
                        logger.debug("Connection check successful")
                    except Exception as e:
                        logger.error(f"Connection check failed: {e}")
                        logger.info("Attempting to reconnect...")
                        self.connected = False
                        self.health_check.mark_unhealthy()
                        self.connect_with_retry()
            except Exception as e:
                logger.error(f"Error in connection monitor: {e}")
            
            time.sleep(60) 

    def start_monitor(self):
        """Start the connection monitor thread"""
        self.monitor_thread = threading.Thread(target=self.monitor_connection, daemon=True)
        self.monitor_thread.start()
        logger.info("Connection monitor started")
    
    def store_message_to_db(self, message):
        """Store a message to TimescaleDB"""
        conn = None
        try:
            conn = self.db_manager.get_connection()
            if not conn:
                logger.error("Failed to get database connection")
                return False
            
            cursor = conn.cursor()
            
            data = message.value
            
            required_fields = ["device_id", "timestamp", "temperature", "humidity", "status", "battery_level"]
            for field in required_fields:
                if field not in data:
                    logger.error(f"Missing required field '{field}' in message: {data}")
                    return False
                
            query = """
                INSERT INTO iot_sensor_data
                (device_id, timestamp, temperature, humidity, status, battery_level)
                VALUES (%s, %s, %s, %s, %s, %s)
            """
            
            cursor.execute(
                query,
                (
                    data["device_id"],
                    data["timestamp"],
                    data["temperature"],
                    data["humidity"],
                    data["status"],
                    data["battery_level"]
                )
            )
            conn.commit()
            cursor.close()
            
            logger.debug(f"Successfully stored data in TimescaleDB for device {data['device_id']}")
            return True
            
        except Exception as e:
            logger.error(f"Error storing data to TimescaleDB: {e}")
            if conn:
                try:
                    conn.rollback()
                except:
                    pass
            return False
        finally:
            if conn:
                self.db_manager.release_connection(conn)

    def process(self):
        """Process messages from Kafka topics"""
        if not self.connect_with_retry():
            logger.critical("Failed to establish initial connection to Kafka. Exiting.")
            return
        self.start_monitor()
        killer = GracefulKiller()
        
        try:
            logger.info(f"Starting consumer for topics: {self.topics}")
            while not killer.kill_now:
                try:
                    records = self.consumer.poll(timeout_ms=1000)
                    
                    for tp, messages in records.items():
                        for message in messages:
                            logger.info(
                                f"Received: Key={message.key}, Value={message.value}, "
                                f"Topic={message.topic}, Partition={message.partition}, "
                                f"Offset={message.offset}"
                            )
                            
                            if self.store_message_to_db(message):
                                logger.info(f"Successfully stored message from device {message.value.get('device_id')}")
                            else:
                                logger.error(f"Failed to store message: {message.value}")
                            self.health_check.mark_healthy()
                except KafkaError as e:
                    logger.error(f"Kafka error during polling: {e}")
                    if not self.connected:
                        logger.info("Connection lost, waiting for monitor to reconnect")
                        time.sleep(5)  
                except Exception as e:
                    logger.error(f"Unexpected error during polling: {e}")
                    time.sleep(5) 
                
        except KeyboardInterrupt:
            logger.info("Consumer interrupted by user")
        except Exception as e:
            logger.exception(f"Unexpected error: {e}")
        finally:
            logger.info("Stopping consumer")
            self.should_monitor = False
            if self.monitor_thread:
                self.monitor_thread.join(timeout=5)
            
            self.health_check.mark_unhealthy()
            if self.consumer:
                try:
                    self.consumer.close()
                except:
                    pass
            self.db_manager.close_all()

if __name__ == "__main__":
    bootstrap_servers = os.environ.get("BOOTSTRAP_SERVERS", "kafka-0:29092,kafka-1:29093,kafka-2:29094").split(",")
    topics = os.environ.get("TOPIC_NAME", "iot_sensor_data").split(",")
    group_id = os.environ.get("GROUP_ID", "iot-group")
    db_config = {
        "host": os.environ.get("DB_HOST", "10.14.7.55"),
        "port": int(os.environ.get("DB_PORT", "5432")),
        "database": os.environ.get("DB_NAME", "sensors_data"),
        "user": os.environ.get("DB_USER", "myuser"),
        "password": os.environ.get("DB_PASSWORD", "mypassword"),
        "connect_timeout": 10,
    }

    logger.info(f"Starting consumer with: Servers={bootstrap_servers}, Topics={topics}, Group={group_id}")
    logger.info(f"Database connection: Host={db_config['host']}, DB={db_config['database']}")

    db_manager = DatabaseManager(db_config)
    if not db_manager.connection_pool:
        logger.critical("Failed to establish initial connection to the database. Exiting...")
        exit(1)  # or sys.exit(1)

    try:
        consumer = Consumer(
            bootstrap_servers=bootstrap_servers,
            topics=topics,
            group_id=group_id,
            db_config=db_config
        )
        consumer.process()
    except Exception as e:
        logger.exception(f"Fatal error in consumer: {e}")
        logger.info("Restarting consumer in 10 seconds...")
        time.sleep(10)

