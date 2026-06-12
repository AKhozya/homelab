-- Create databases
CREATE DATABASE IF NOT EXISTS homeassistant;
CREATE DATABASE IF NOT EXISTS uptimekuma;
CREATE DATABASE IF NOT EXISTS pricebuddy;

-- Create users and grant permissions
CREATE USER IF NOT EXISTS 'homeassistant'@'%' IDENTIFIED BY '<value>';
GRANT ALL PRIVILEGES ON homeassistant.* TO 'homeassistant'@'%';

CREATE USER IF NOT EXISTS 'uptimekuma'@'%' IDENTIFIED BY '<value>';
GRANT ALL PRIVILEGES ON uptimekuma.* TO 'uptimekuma'@'%';

CREATE USER IF NOT EXISTS 'pricebuddy'@'%' IDENTIFIED BY '<value>';
GRANT ALL PRIVILEGES ON pricebuddy.* TO 'pricebuddy'@'%';

FLUSH PRIVILEGES;
SHOW DATABASES;
