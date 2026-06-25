CREATE DATABASE IF NOT EXISTS taxi_db 
CHARACTER SET utf8mb4 
COLLATE utf8mb4_unicode_ci;

USE taxi_db;



CREATE TABLE clients (
    client_id   INT AUTO_INCREMENT PRIMARY KEY,
    full_name   VARCHAR(150) NOT NULL,
    phone       VARCHAR(20) NOT NULL UNIQUE,
    email       VARCHAR(100),
    reg_date    DATE DEFAULT (CURDATE()),
    status      VARCHAR(20) DEFAULT 'active'
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE drivers (
    driver_id       INT AUTO_INCREMENT PRIMARY KEY,
    full_name       VARCHAR(150) NOT NULL,
    phone           VARCHAR(20) NOT NULL UNIQUE,
    license_number  VARCHAR(20) NOT NULL UNIQUE,
    status          VARCHAR(20) DEFAULT 'available',
    rating          DECIMAL(3,2) DEFAULT 5.00
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE cars (
    car_id       INT AUTO_INCREMENT PRIMARY KEY,
    driver_id    INT,
    model        VARCHAR(100) NOT NULL,
    plate_number VARCHAR(15) NOT NULL UNIQUE,
    color        VARCHAR(30),
    year         INT,
    CONSTRAINT fk_cars_drivers FOREIGN KEY (driver_id) 
        REFERENCES drivers(driver_id) ON DELETE SET NULL,
    CONSTRAINT chk_year CHECK (year BETWEEN 1990 AND 2099)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE orders (
    order_id       INT AUTO_INCREMENT PRIMARY KEY,
    client_id      INT,
    driver_id      INT,
    car_id         INT,
    pickup_address VARCHAR(255) NOT NULL,
    destination    VARCHAR(255) NOT NULL,
    order_date     TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    status         VARCHAR(20) DEFAULT 'new',
    total_cost     DECIMAL(10,2) NOT NULL,
    CONSTRAINT fk_orders_clients FOREIGN KEY (client_id) 
        REFERENCES clients(client_id),
    CONSTRAINT fk_orders_drivers FOREIGN KEY (driver_id) 
        REFERENCES drivers(driver_id),
    CONSTRAINT fk_orders_cars FOREIGN KEY (car_id) 
        REFERENCES cars(car_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE payments (
    payment_id      INT AUTO_INCREMENT PRIMARY KEY,
    order_id        INT,
    amount          DECIMAL(10,2) NOT NULL,
    payment_method  VARCHAR(30) NOT NULL,
    payment_date    TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT fk_payments_orders FOREIGN KEY (order_id) 
        REFERENCES orders(order_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE reviews (
    review_id    INT AUTO_INCREMENT PRIMARY KEY,
    order_id     INT,
    client_id    INT,
    driver_id    INT,
    rating       INT,
    comment      TEXT,
    review_date  DATE DEFAULT (CURDATE()),
    CONSTRAINT fk_reviews_orders FOREIGN KEY (order_id) 
        REFERENCES orders(order_id),
    CONSTRAINT fk_reviews_clients FOREIGN KEY (client_id) 
        REFERENCES clients(client_id),
    CONSTRAINT fk_reviews_drivers FOREIGN KEY (driver_id) 
        REFERENCES drivers(driver_id),
    CONSTRAINT chk_rating CHECK (rating BETWEEN 1 AND 5)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;



CREATE USER IF NOT EXISTS 'taxi_admin'@'localhost' IDENTIFIED BY 'admin_pass';
GRANT ALL PRIVILEGES ON taxi_db.* TO 'taxi_admin'@'localhost';

CREATE USER IF NOT EXISTS 'taxi_manager'@'localhost' IDENTIFIED BY 'manager_pass';
GRANT SELECT, INSERT, UPDATE ON taxi_db.clients TO 'taxi_manager'@'localhost';
GRANT SELECT, INSERT, UPDATE ON taxi_db.orders TO 'taxi_manager'@'localhost';
GRANT SELECT, INSERT ON taxi_db.payments TO 'taxi_manager'@'localhost';

CREATE USER IF NOT EXISTS 'taxi_driver'@'localhost' IDENTIFIED BY 'driver_pass';
GRANT SELECT ON taxi_db.orders TO 'taxi_driver'@'localhost';
GRANT SELECT ON taxi_db.cars TO 'taxi_driver'@'localhost';

FLUSH PRIVILEGES;



CREATE OR REPLACE VIEW v_order_summary AS
SELECT 
    o.order_id,
    c.full_name AS client_name,
    c.phone AS client_phone,
    d.full_name AS driver_name,
    d.phone AS driver_phone,
    ca.model AS car_model,
    ca.plate_number,
    o.pickup_address,
    o.destination,
    o.order_date,
    o.total_cost,
    o.status
FROM orders o
INNER JOIN clients c ON c.client_id = o.client_id
INNER JOIN drivers d ON d.driver_id = o.driver_id
INNER JOIN cars ca ON ca.car_id = o.car_id;



DELIMITER $$

CREATE FUNCTION calculate_fare(p_distance_km DECIMAL(10,2)) 
RETURNS DECIMAL(10,2)
DETERMINISTIC
READS SQL DATA
BEGIN
    DECLARE v_base_fare DECIMAL(10,2) DEFAULT 100.00;
    DECLARE v_per_km_rate DECIMAL(10,2) DEFAULT 25.00;
    DECLARE v_total_fare DECIMAL(10,2);
    
    SET v_total_fare = v_base_fare + (p_distance_km * v_per_km_rate);
    
    RETURN v_total_fare;
END$$

DELIMITER ;



DELIMITER $$

CREATE PROCEDURE create_order(
    IN p_client_id INT,
    IN p_driver_id INT,
    IN p_car_id INT,
    IN p_pickup VARCHAR(255),
    IN p_dest VARCHAR(255),
    IN p_cost DECIMAL(10,2),
    OUT p_order_id INT,
    OUT p_status VARCHAR(50)
)
BEGIN
    DECLARE v_driver_status VARCHAR(20);
    DECLARE v_driver_exists INT DEFAULT 0;
    
    -- Обработчик ошибок
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        GET DIAGNOSTICS CONDITION 1 p_status = MESSAGE_TEXT;
        SET p_order_id = -1;
        ROLLBACK;
    END;
    
    START TRANSACTION;
    
    -- Проверка существования водителя
    SELECT COUNT(*), COALESCE(MAX(status), '') 
    INTO v_driver_exists, v_driver_status
    FROM drivers 
    WHERE driver_id = p_driver_id;
    
    IF v_driver_exists = 0 THEN
        SET p_order_id = -1;
        SET p_status = 'Водитель не найден';
        ROLLBACK;
    ELSEIF v_driver_status <> 'available' THEN
        SET p_order_id = -1;
        SET p_status = CONCAT('Водитель недоступен (', v_driver_status, ')');
        ROLLBACK;
    ELSE
        -- Создание заказа
        INSERT INTO orders(client_id, driver_id, car_id, 
                          pickup_address, destination, total_cost, status)
        VALUES (p_client_id, p_driver_id, p_car_id,
                p_pickup, p_dest, p_cost, 'in_progress');
        
        SET p_order_id = LAST_INSERT_ID();
        
        -- Обновление статуса водителя
        UPDATE drivers 
        SET status = 'busy' 
        WHERE driver_id = p_driver_id;
        
        SET p_status = 'Заказ успешно создан';
        COMMIT;
    END IF;
END$$

DELIMITER ;



DELIMITER $$

CREATE TRIGGER trg_after_review_insert
AFTER INSERT ON reviews
FOR EACH ROW
BEGIN
    DECLARE v_avg_rating DECIMAL(3,2);
    
    -- Вычисление среднего рейтинга
    SELECT AVG(rating) INTO v_avg_rating
    FROM reviews 
    WHERE driver_id = NEW.driver_id;
    
    -- Обновление рейтинга водителя
    UPDATE drivers 
    SET rating = IFNULL(v_avg_rating, 5.00)
    WHERE driver_id = NEW.driver_id;
END$$

DELIMITER ;



INSERT INTO clients (full_name, phone, email) VALUES
('Иванов Иван', '+79001112233', 'ivanov@mail.ru'),
('Петров Пётр', '+79004445566', 'petrov@mail.ru'),
('Сидорова Анна', '+79007778899', 'sidorova@mail.ru');

INSERT INTO drivers (full_name, phone, license_number) VALUES
('Смирнов Алексей', '+79001234567', 'DL123456'),
('Козлов Дмитрий', '+79007654321', 'DL789012'),
('Новиков Сергей', '+79009876543', 'DL345678');

INSERT INTO cars (driver_id, model, plate_number, color, year) VALUES
(1, 'Toyota Camry', 'А123БВ777', 'black', 2020),
(2, 'Hyundai Solaris', 'В456ГД777', 'white', 2019),
(3, 'Kia Rio', 'Е789ЖЗ777', 'silver', 2021);