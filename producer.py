import os
import time
import logging
import json
import random
import datetime
import ssl
from kafka import KafkaProducer
from kafka.errors import KafkaError

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

class IoTData:
    def __init__(self, device_id: str, temperature: float, humidity: float, status: str, battery_level: float):
        self.device_id = device_id
        self.timestamp = datetime.datetime.now(datetime.timezone.utc)
        self.temperature = temperature
        self.humidity = humidity
        self.status = status
        self.battery_level = battery_level

    def asdict(self):
        return {
            "device_id": self.device_id,
            "timestamp": self.timestamp.isoformat(),
            "temperature": self.temperature,
            "humidity": self.humidity,
            "status": self.status,
            "battery_level": self.battery_level
        }

    @classmethod
    def generate(cls, device_id: str):
        temperature = random.uniform(20.0, 30.0)  
        humidity = random.uniform(30.0, 70.0)    
        status = random.choice(["active", "inactive", "error"])  
        battery_level = random.uniform(10.0, 100.0)  
        return cls(device_id, temperature, humidity, status, battery_level)

class Producer:
    def __init__(self, bootstrap_servers: list, topic: str):
        self.bootstrap_servers = bootstrap_servers
        self.topic = topic
        self.producer = self.create()

    def create(self):
        ssl_context = ssl.create_default_context()
        
        ca_cert = "/home/pradeep/Desktop/Kafka_Setup/latest-method/pem/ca-root.pem"
        client_cert = "/home/pradeep/Desktop/Kafka_Setup/latest-method/pem/client-certificate.pem"
        client_key = "/home/pradeep/Desktop/Kafka_Setup/latest-method/pem/client-private-key.pem"
        ssl_context.load_verify_locations(ca_cert)
        ssl_context.load_cert_chain(certfile=client_cert, keyfile=client_key)
        
        logger.info(f"Connecting to bootstrap servers: {self.bootstrap_servers}")
        
        return KafkaProducer(
            bootstrap_servers=self.bootstrap_servers,
            security_protocol="SASL_SSL",
            sasl_mechanism="PLAIN",
            sasl_plain_username="sa",
            sasl_plain_password="000000",
            ssl_context=ssl_context,
            value_serializer=lambda v: json.dumps(v).encode("utf-8"),
            key_serializer=lambda v: v.encode("utf-8"),
            api_version_auto_timeout_ms=30000,  
            request_timeout_ms=60000,  
        )

    def send(self, device_data: IoTData):
        try:
            data_dict = device_data.asdict()
            logger.info(f"Sending data: {data_dict}")
            
            future = self.producer.send(
                self.topic, key=device_data.device_id, value=data_dict
            )
            
            record_metadata = future.get(timeout=10)
            
            logger.info(f"Message sent successfully to {record_metadata.topic} "
                        f"[partition={record_metadata.partition}, offset={record_metadata.offset}]")
            
            self.producer.flush()
            return True
            
        except KafkaError as e:
            logger.error(f"Failed to send message: {e}")
            return False
        except Exception as e:
            logger.error(f"Unexpected error while sending message: {e}")
            return False

def list_topics(producer):
    """List available topics to verify connectivity"""
    try:
        cluster_metadata = producer.producer._client.cluster
        topics = cluster_metadata.topics()
        logger.info(f"Available topics: {topics}")
        return topics
    except Exception as e:
        logger.error(f"Failed to list topics: {e}")
        return []

if __name__ == "__main__":
    bootstrap_servers = "10.14.7.55:29092,10.14.7.55:29093,10.14.7.55:29094"
    topic_name = os.getenv("TOPIC_NAME", "iot_sensor_data")
    
    producer = Producer(
        bootstrap_servers=os.getenv("BOOTSTRAP_SERVERS", bootstrap_servers).split(","),
        topic=topic_name,
    )
    
    list_topics(producer)
    
    max_run = int(os.getenv("MAX_RUN", "10"))
    logger.info(f"Will send {max_run} messages to topic '{topic_name}'")
    current_run = 0
    
    try:
        while True:
            current_run += 1
            logger.info(f"Sending message {current_run}/{max_run}")
            
            device_data = IoTData.generate(device_id=f"device_{random.randint(1, 5):03d}")
            success = producer.send(device_data)
            
            if not success:
                logger.error("Failed to send message, retrying in 5 seconds")
                time.sleep(5)
                continue
                
            if current_run >= max_run and max_run > 0:
                logger.info(f"Sent {max_run} messages, finishing")
                producer.producer.close()
                break
                
            time.sleep(1)
            
    except KeyboardInterrupt:
        logger.info("Producer interrupted by user, closing...")
    except Exception as e:
        logger.error(f"Error in producer: {e}")
    finally:
        producer.producer.close()
        logger.info("Producer closed")