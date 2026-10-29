-- =====================================================================
-- NRG Data Warehouse - DDL (MySQL 8.x)
-- Skema mengikuti Bagian 3.1 laporan: 1 fakta + 5 dimensi,
-- ditambah tabel staging dan tabel pendukung untuk ETL Pentaho.
-- Jalankan dari kondisi kosong:  mysql -u root -p < 01_ddl_nrg_dw.sql
-- PERINGATAN: skrip ini menjalankan DROP DATABASE nrg_dw.
-- =====================================================================

DROP DATABASE IF EXISTS nrg_dw;
CREATE DATABASE nrg_dw CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE nrg_dw;

-- ---------------------------------------------------------------------
-- 1. DIMENSI
-- ---------------------------------------------------------------------

-- sk_tanggal berupa integer YYYYMMDD (dibangkitkan lewat Generate Rows)
CREATE TABLE dim_tanggal (
  sk_tanggal    INT          NOT NULL,
  tanggal       DATE         NOT NULL,
  tahun         SMALLINT     NOT NULL,
  kuartal       TINYINT      NOT NULL,
  bulan         TINYINT      NOT NULL,
  tahun_kuartal CHAR(7)      NOT NULL,           -- contoh: 2023-Q1
  PRIMARY KEY (sk_tanggal),
  UNIQUE KEY uq_dim_tanggal_tanggal (tanggal)
) ENGINE=InnoDB;

-- 1 baris per material_no (SCD Tipe 1).
-- Baris late-arriving (ORD-9999): sumber_master = 'ECOM', material_no = SKU S1.
CREATE TABLE dim_produk (
  sk_produk      INT          NOT NULL AUTO_INCREMENT,
  material_no    VARCHAR(30)  NOT NULL,
  nama_produk    VARCHAR(150) NULL,
  brand          VARCHAR(60)  NULL,
  kategori       VARCHAR(60)  NULL,
  sub_kategori   VARCHAR(60)  NULL,
  nama_supplier  VARCHAR(100) NULL,
  sumber_master  VARCHAR(10)  NOT NULL DEFAULT 'ERP',   -- 'ERP' atau 'ECOM'
  PRIMARY KEY (sk_produk),
  UNIQUE KEY uq_dim_produk_material (material_no)
) ENGINE=InnoDB;

-- 45 baris: 42 Toko Fisik + WEB + marketplace_a + marketplace_b
CREATE TABLE dim_kanal (
  sk_kanal     INT          NOT NULL AUTO_INCREMENT,
  kanal        VARCHAR(20)  NOT NULL,                  -- Situs Web / Toko Fisik / Marketplace
  outlet_kode  VARCHAR(20)  NOT NULL,                  -- WEB, TS01..TS42, marketplace_a/b
  nama_outlet  VARCHAR(100) NULL,
  kota         VARCHAR(60)  NULL,
  PRIMARY KEY (sk_kanal),
  UNIQUE KEY uq_dim_kanal_outlet (outlet_kode)
) ENGINE=InnoDB;

-- 1 baris per orang/identitas. sk = -1 dipakai untuk pembeli toko tanpa member (WALKIN).
-- Kolom identitas boleh NULL; UNIQUE di MySQL mengizinkan banyak NULL.
CREATE TABLE dim_pelanggan (
  sk_pelanggan       INT          NOT NULL AUTO_INCREMENT,
  hp_normal          CHAR(11)     NULL,
  customer_id_web    VARCHAR(20)  NULL,
  member_no          VARCHAR(20)  NULL,
  buyer_hash         VARCHAR(64)  NULL,
  nama_pelanggan     VARCHAR(100) NULL,
  kota               VARCHAR(60)  NULL,
  ada_akun_web       CHAR(1)      NOT NULL DEFAULT 'N',
  ada_member_toko    CHAR(1)      NOT NULL DEFAULT 'N',
  sumber_identitas   VARCHAR(20)  NOT NULL,            -- WEB / MEMBER / WEB+MEMBER / MARKETPLACE / WALK-IN
  PRIMARY KEY (sk_pelanggan),
  UNIQUE KEY uq_dim_pelanggan_web    (customer_id_web),
  UNIQUE KEY uq_dim_pelanggan_member (member_no),
  UNIQUE KEY uq_dim_pelanggan_buyer  (buyer_hash),
  KEY ix_dim_pelanggan_hp (hp_normal),
  CONSTRAINT ck_dim_pelanggan_web    CHECK (ada_akun_web    IN ('Y','N')),
  CONSTRAINT ck_dim_pelanggan_member CHECK (ada_member_toko IN ('Y','N'))
) ENGINE=InnoDB;

-- sk = -1 (TANPA_PROMO) dan sk = -2 (TIDAK_VALID) di-seed di bagian 4.
CREATE TABLE dim_kampanye (
  sk_kampanye           INT           NOT NULL AUTO_INCREMENT,
  kode_promo            VARCHAR(30)   NOT NULL,
  nama_kampanye         VARCHAR(100)  NULL,
  jenis_promo           VARCHAR(40)   NULL,
  kanal_sasaran         VARCHAR(20)   NULL,            -- Semua Kanal / Toko Fisik / Situs Web / Marketplace
  tgl_mulai             DATE          NULL,
  tgl_selesai           DATE          NULL,
  target_diskon_persen  DECIMAL(5,2)  NULL,
  PRIMARY KEY (sk_kampanye),
  UNIQUE KEY uq_dim_kampanye_kode_mulai (kode_promo, tgl_mulai)
) ENGINE=InnoDB;

-- ---------------------------------------------------------------------
-- 2. FAKTA
-- ---------------------------------------------------------------------
CREATE TABLE fact_penjualan (
  sk_penjualan        BIGINT        NOT NULL AUTO_INCREMENT,
  sk_tanggal          INT           NOT NULL,
  sk_produk           INT           NOT NULL,
  sk_kanal            INT           NOT NULL,
  sk_pelanggan        INT           NOT NULL,
  sk_kampanye         INT           NOT NULL,
  sumber_sistem       CHAR(2)       NOT NULL,          -- S1 / S2 / S3
  no_transaksi        VARCHAR(40)   NOT NULL,
  no_baris            VARCHAR(40)   NOT NULL,          -- line_no / line_seq / seller_sku
  waktu_transaksi     DATETIME      NOT NULL,          -- WIB
  qty                 INT           NOT NULL,
  penjualan_kotor     DECIMAL(18,2) NOT NULL,          -- tanpa PPN
  diskon              DECIMAL(18,2) NOT NULL DEFAULT 0,
  penjualan_bersih    DECIMAL(18,2) NOT NULL,
  total_harga_pokok   DECIMAL(18,2) NULL,              -- NULL jika HPP tidak ditemukan di S4
  fee_komisi          DECIMAL(18,2) NOT NULL DEFAULT 0,
  fee_layanan         DECIMAL(18,2) NOT NULL DEFAULT 0,
  margin_kotor        DECIMAL(18,2) NULL,              -- NULL jika total_harga_pokok NULL
  atribusi_kampanye   VARCHAR(15)   NOT NULL,          -- KODE_VOUCHER / JENDELA_WAKTU / TIDAK_ADA
  flag_hpp_kosong     TINYINT(1)    NOT NULL DEFAULT 0,
  PRIMARY KEY (sk_penjualan),
  UNIQUE KEY uq_fact_natural (sumber_sistem, no_transaksi, no_baris),
  KEY ix_fact_tanggal   (sk_tanggal),
  KEY ix_fact_produk    (sk_produk),
  KEY ix_fact_kanal     (sk_kanal),
  KEY ix_fact_pelanggan (sk_pelanggan),
  KEY ix_fact_kampanye  (sk_kampanye),
  CONSTRAINT fk_fact_tanggal   FOREIGN KEY (sk_tanggal)   REFERENCES dim_tanggal   (sk_tanggal),
  CONSTRAINT fk_fact_produk    FOREIGN KEY (sk_produk)    REFERENCES dim_produk    (sk_produk),
  CONSTRAINT fk_fact_kanal     FOREIGN KEY (sk_kanal)     REFERENCES dim_kanal     (sk_kanal),
  CONSTRAINT fk_fact_pelanggan FOREIGN KEY (sk_pelanggan) REFERENCES dim_pelanggan (sk_pelanggan),
  CONSTRAINT fk_fact_kampanye  FOREIGN KEY (sk_kampanye)  REFERENCES dim_kampanye  (sk_kampanye),
  CONSTRAINT ck_fact_sumber    CHECK (sumber_sistem IN ('S1','S2','S3')),
  CONSTRAINT ck_fact_atribusi  CHECK (atribusi_kampanye IN ('KODE_VOUCHER','JENDELA_WAKTU','TIDAK_ADA'))
) ENGINE=InnoDB;

-- ---------------------------------------------------------------------
-- 3. STAGING DAN TABEL PENDUKUNG ETL
-- ---------------------------------------------------------------------

-- Skema gabungan tiga aliran (S1, S2, S3) sebelum lookup ke dimensi.
-- Presisi 4 desimal agar pembagian 1,11 dan alokasi fee tidak terpotong dini.
CREATE TABLE stg_penjualan (
  sumber_sistem          CHAR(2)       NOT NULL,
  no_transaksi           VARCHAR(40)   NOT NULL,
  no_baris               VARCHAR(40)   NOT NULL,
  waktu_transaksi        DATETIME      NOT NULL,
  outlet_kode            VARCHAR(20)   NOT NULL,
  material_no            VARCHAR(30)   NOT NULL,
  id_pelanggan           VARCHAR(40)   NULL,
  kode_promo             VARCHAR(30)   NULL,
  tgl_mulai_promo        DATE          NULL,
  qty                    INT           NOT NULL,
  harga_satuan_excl_ppn  DECIMAL(18,4) NOT NULL,
  diskon                 DECIMAL(18,4) NOT NULL DEFAULT 0,
  fee_komisi             DECIMAL(18,4) NOT NULL DEFAULT 0,
  fee_layanan            DECIMAL(18,4) NOT NULL DEFAULT 0,
  KEY ix_stg_penjualan_natural (sumber_sistem, no_transaksi, no_baris)
) ENGINE=InnoDB;

-- Riwayat harga pokok dari S4 produk_master (semua versi berlaku_sejak).
CREATE TABLE stg_hpp (
  material_no   VARCHAR(30)   NOT NULL,
  harga_pokok   DECIMAL(18,2) NOT NULL,
  berlaku_sejak DATE          NOT NULL,
  PRIMARY KEY (material_no, berlaku_sejak)
) ENGINE=InnoDB;

-- Pemetaan SKU katalog S1 ke material_no S4.
-- S2 (item_code) dan S3 (seller_sku) diturunkan lewat aturan di peta, tidak perlu tabel.
CREATE TABLE map_produk (
  sku_ecom      VARCHAR(40)  NOT NULL,
  nama_ecom     VARCHAR(150) NULL,
  material_no   VARCHAR(30)  NULL,                     -- NULL = belum terdaftar di S4 (kasus ORD-9999)
  keterangan    VARCHAR(100) NULL,
  PRIMARY KEY (sku_ecom)
) ENGINE=InnoDB;

-- Tabel referensi kota (dimuat dari ref_kota.csv) untuk lookup alias -> kota baku.
CREATE TABLE ref_kota (
  alias      VARCHAR(60) NOT NULL,
  kota_baku  VARCHAR(60) NOT NULL,
  PRIMARY KEY (alias)
) ENGINE=InnoDB;

-- Baris S5 yang gagal validasi (mis. target_diskon_persen = 'sepuluh').
-- Nilai disimpan mentah (teks) agar tidak ada yang dipaksa menjadi angka.
CREATE TABLE err_kampanye (
  id_error              INT           NOT NULL AUTO_INCREMENT,
  kode_promo            VARCHAR(60)   NULL,
  nama_kampanye         VARCHAR(150)  NULL,
  jenis_promo           VARCHAR(60)   NULL,
  kanal                 VARCHAR(40)   NULL,
  tgl_mulai             VARCHAR(30)   NULL,
  tgl_selesai           VARCHAR(30)   NULL,
  target_diskon_persen  VARCHAR(30)   NULL,
  pic                   VARCHAR(60)   NULL,
  alasan                VARCHAR(200)  NOT NULL,
  waktu_muat            TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id_error)
) ENGINE=InnoDB;

-- ---------------------------------------------------------------------
-- 4. BARIS KHUSUS (SEED)
-- ---------------------------------------------------------------------
INSERT INTO dim_pelanggan
  (sk_pelanggan, nama_pelanggan, ada_akun_web, ada_member_toko, sumber_identitas)
VALUES
  (-1, 'Non-member (walk-in)', 'N', 'N', 'WALK-IN');

INSERT INTO dim_kampanye
  (sk_kampanye, kode_promo, nama_kampanye, jenis_promo, kanal_sasaran)
VALUES
  (-1, 'TANPA_PROMO', 'Tanpa kampanye', NULL, NULL),
  (-2, 'TIDAK_VALID', 'Kampanye data tidak valid', NULL, NULL);
