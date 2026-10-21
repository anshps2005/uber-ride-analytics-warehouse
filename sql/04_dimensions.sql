-- =============================================================================
-- 04_dimensions.sql
-- Conformed dimensions for the bookings star schema. Surrogate keys are stable
-- across runs because dimension loads only ever insert new members.
-- =============================================================================

-- Calendar dimension (replaces the DAX 'Calender' table).
CREATE TABLE IF NOT EXISTS dw.dim_date (
    date_key        integer  PRIMARY KEY,              -- yyyymmdd
    full_date       date     NOT NULL UNIQUE,
    year            smallint NOT NULL,
    quarter         smallint NOT NULL CHECK (quarter BETWEEN 1 AND 4),
    quarter_label   text     NOT NULL,                 -- 'Q1'
    month_no        smallint NOT NULL CHECK (month_no BETWEEN 1 AND 12),
    month_name      text     NOT NULL,                 -- 'January'
    month_short     text     NOT NULL,                 -- 'Jan'
    day_of_month    smallint NOT NULL,
    iso_weekday     smallint NOT NULL CHECK (iso_weekday BETWEEN 1 AND 7),  -- 1 = Monday
    weekday_short   text     NOT NULL,                 -- 'Mon'
    is_weekend      boolean  NOT NULL
);

-- Three-hour demand windows (replaces the DAX 'Time Slot' / 'Time Slot Sort' columns).
CREATE TABLE IF NOT EXISTS dw.dim_time_slot (
    time_slot_key   smallint PRIMARY KEY,              -- also the sort order
    time_slot_label text     NOT NULL UNIQUE,
    start_hour      smallint NOT NULL,
    end_hour        smallint NOT NULL
);

INSERT INTO dw.dim_time_slot (time_slot_key, time_slot_label, start_hour, end_hour) VALUES
    (1, '12 AM - 03 AM',  0,  3),
    (2, '03 AM - 06 AM',  3,  6),
    (3, '06 AM - 09 AM',  6,  9),
    (4, '09 AM - 12 PM',  9, 12),
    (5, '12 PM - 03 PM', 12, 15),
    (6, '03 PM - 06 PM', 15, 18),
    (7, '06 PM - 09 PM', 18, 21),
    (8, '09 PM - 12 AM', 21, 24)
ON CONFLICT (time_slot_key) DO NOTHING;

CREATE TABLE IF NOT EXISTS dw.dim_vehicle (
    vehicle_key     smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    vehicle_type    text NOT NULL UNIQUE,              -- 'Bike', 'eBike', 'Go Sedan', ...
    vehicle_group   text NOT NULL                      -- Bike + eBike rolled up (DAX Ve_Type)
);

CREATE TABLE IF NOT EXISTS dw.dim_location (
    location_key    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    location_name   text NOT NULL UNIQUE
);

CREATE TABLE IF NOT EXISTS dw.dim_customer (
    customer_key        integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_id         text NOT NULL UNIQUE,
    first_booking_date  date,
    last_booking_date   date
);

CREATE TABLE IF NOT EXISTS dw.dim_payment_method (
    payment_method_key  smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    payment_method      text NOT NULL UNIQUE
);

CREATE TABLE IF NOT EXISTS dw.dim_booking_status (
    status_key      smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    booking_status  text    NOT NULL UNIQUE,
    status_category text    NOT NULL
                    CHECK (status_category IN ('Completed', 'Cancelled', 'Incomplete', 'No Driver')),
    is_completed    boolean NOT NULL
);

CREATE TABLE IF NOT EXISTS dw.dim_cancellation_reason (
    cancellation_reason_key integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    reason_source   text NOT NULL CHECK (reason_source IN ('Customer', 'Driver', 'Incomplete')),
    reason          text NOT NULL,
    UNIQUE (reason_source, reason)
);
