-- OpenData Database Schema for Denodo POC
-- French SIRENE Companies + Population Data
-- PostgreSQL 15.4

-- Create schema
CREATE SCHEMA IF NOT EXISTS opendata;

-- Set search path
SET search_path TO opendata;

--------------------------------------------------------------------------------
-- Table 1: French Companies (SIRENE Data)
--------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS entreprises (
    siren VARCHAR(9) PRIMARY KEY,
    nom_raison_sociale VARCHAR(255) NOT NULL,
    sigle VARCHAR(100),
    forme_juridique VARCHAR(100),
    forme_juridique_code VARCHAR(10),
    date_creation DATE,
    date_cessation DATE,
    statut VARCHAR(50) DEFAULT 'Actif',
    
    -- Address
    numero_voie VARCHAR(10),
    indice_repetition VARCHAR(10),
    type_voie VARCHAR(50),
    libelle_voie VARCHAR(255),
    complement_adresse VARCHAR(255),
    code_postal VARCHAR(5),
    ville VARCHAR(100),
    code_commune VARCHAR(10),
    departement VARCHAR(3),
    region VARCHAR(3),
    pays VARCHAR(100) DEFAULT 'France',
    
    -- Activity
    code_naf VARCHAR(10),
    libelle_naf VARCHAR(255),
    activite_principale TEXT,
    
    -- Size
    effectif VARCHAR(50),
    tranche_effectif VARCHAR(10),
    annee_effectif INTEGER,
    
    -- Financial
    capital_social DECIMAL(15,2),
    devise_capital VARCHAR(10) DEFAULT 'EUR',
    
    -- Metadata
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Indexes for performance
CREATE INDEX idx_entreprises_postal ON entreprises(code_postal);
CREATE INDEX idx_entreprises_ville ON entreprises(ville);
CREATE INDEX idx_entreprises_dept ON entreprises(departement);
CREATE INDEX idx_entreprises_region ON entreprises(region);
CREATE INDEX idx_entreprises_naf ON entreprises(code_naf);
CREATE INDEX idx_entreprises_statut ON entreprises(statut);
CREATE INDEX idx_entreprises_effectif ON entreprises(tranche_effectif);
CREATE INDEX idx_entreprises_date_creation ON entreprises(date_creation);

COMMENT ON TABLE entreprises IS 'French companies from SIRENE open data registry';

--------------------------------------------------------------------------------
-- Table 2: Population by Commune
--------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS population_communes (
    code_commune VARCHAR(10) PRIMARY KEY,
    nom_commune VARCHAR(100) NOT NULL,
    nom_commune_complet VARCHAR(255),
    
    -- Geographic codes
    code_postal VARCHAR(5),
    codes_postaux TEXT[], -- Array for multiple postal codes
    code_departement VARCHAR(3),
    nom_departement VARCHAR(100),
    code_region VARCHAR(3),
    nom_region VARCHAR(100),
    
    -- Population data
    population INTEGER,
    population_municipale INTEGER,
    population_comptee_part INTEGER,
    population_totale INTEGER,
    
    -- Geographic data
    superficie DECIMAL(10,2), -- in km²
    densite DECIMAL(10,2), -- inhabitants per km²
    altitude_min INTEGER,
    altitude_max INTEGER,
    
    -- Coordinates
    latitude DECIMAL(10,7),
    longitude DECIMAL(10,7),
    
    -- Reference year
    annee INTEGER DEFAULT 2023,
    
    -- Metadata
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Indexes
CREATE INDEX idx_population_postal ON population_communes(code_postal);
CREATE INDEX idx_population_dept ON population_communes(code_departement);
CREATE INDEX idx_population_region ON population_communes(code_region);
CREATE INDEX idx_population_size ON population_communes(population);
CREATE INDEX idx_population_name ON population_communes(nom_commune);

COMMENT ON TABLE population_communes IS 'French communes with population and geographic data (2023)';

--------------------------------------------------------------------------------
-- View: Companies with Population Context
--------------------------------------------------------------------------------
CREATE OR REPLACE VIEW entreprises_population AS
SELECT 
    e.siren,
    e.nom_raison_sociale,
    e.sigle,
    e.forme_juridique,
    e.date_creation,
    e.ville,
    e.code_postal,
    e.departement,
    e.region,
    e.code_naf,
    e.libelle_naf,
    e.effectif,
    e.tranche_effectif,
    e.statut,
    
    p.nom_commune,
    p.nom_departement,
    p.nom_region,
    p.population,
    p.population_municipale,
    p.densite,
    p.superficie,
    p.latitude,
    p.longitude,
    
    -- Categorization
    CASE 
        WHEN p.population < 2000 THEN 'Petite commune'
        WHEN p.population < 10000 THEN 'Commune moyenne'
        WHEN p.population < 50000 THEN 'Grande commune'
        WHEN p.population < 100000 THEN 'Très grande ville'
        ELSE 'Métropole'
    END as categorie_commune,
    
    CASE 
        WHEN e.tranche_effectif IN ('00', '01', '02') THEN 'TPE (0-19 salariés)'
        WHEN e.tranche_effectif IN ('03', '11') THEN 'PME (20-249 salariés)'
        WHEN e.tranche_effectif IN ('12', '21') THEN 'ETI (250-4999 salariés)'
        ELSE 'Grande entreprise (5000+ salariés)'
    END as categorie_entreprise
    
FROM entreprises e
LEFT JOIN population_communes p 
    ON e.code_postal = p.code_postal
WHERE e.statut = 'Actif';

COMMENT ON VIEW entreprises_population IS 'Active companies joined with commune population data';

--------------------------------------------------------------------------------
-- View: Statistics by Department
--------------------------------------------------------------------------------
CREATE OR REPLACE VIEW stats_departement AS
SELECT 
    e.departement,
    p.nom_departement,
    COUNT(DISTINCT e.siren) as nombre_entreprises,
    COUNT(DISTINCT e.code_commune) as nombre_communes,
    AVG(p.population) as population_moyenne,
    SUM(p.population) as population_totale,
    
    -- By sector
    COUNT(DISTINCT CASE WHEN e.code_naf LIKE '01%' THEN e.siren END) as agriculture,
    COUNT(DISTINCT CASE WHEN e.code_naf LIKE '10%' OR e.code_naf LIKE '11%' THEN e.siren END) as industrie,
    COUNT(DISTINCT CASE WHEN e.code_naf LIKE '41%' OR e.code_naf LIKE '42%' THEN e.siren END) as construction,
    COUNT(DISTINCT CASE WHEN e.code_naf LIKE '45%' OR e.code_naf LIKE '46%' OR e.code_naf LIKE '47%' THEN e.siren END) as commerce,
    COUNT(DISTINCT CASE WHEN e.code_naf LIKE '62%' OR e.code_naf LIKE '63%' THEN e.siren END) as informatique,
    
    -- By size
    COUNT(DISTINCT CASE WHEN e.tranche_effectif IN ('00', '01', '02') THEN e.siren END) as tpe,
    COUNT(DISTINCT CASE WHEN e.tranche_effectif IN ('03', '11') THEN e.siren END) as pme,
    COUNT(DISTINCT CASE WHEN e.tranche_effectif IN ('12', '21') THEN e.siren END) as eti,
    COUNT(DISTINCT CASE WHEN e.tranche_effectif IN ('22', '31', '32', '41', '42', '51', '52', '53') THEN e.siren END) as grandes_entreprises

FROM entreprises e
LEFT JOIN population_communes p ON e.departement = p.code_departement
WHERE e.statut = 'Actif'
GROUP BY e.departement, p.nom_departement
ORDER BY nombre_entreprises DESC;

COMMENT ON VIEW stats_departement IS 'Company and population statistics by department';

--------------------------------------------------------------------------------
-- Function: Search companies by criteria
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION search_entreprises(
    p_departement VARCHAR DEFAULT NULL,
    p_code_naf VARCHAR DEFAULT NULL,
    p_effectif_min VARCHAR DEFAULT NULL,
    p_ville VARCHAR DEFAULT NULL,
    p_limit INTEGER DEFAULT 100
)
RETURNS TABLE (
    siren VARCHAR,
    nom VARCHAR,
    ville VARCHAR,
    departement VARCHAR,
    activite VARCHAR,
    effectif VARCHAR,
    population INTEGER
) AS $$
BEGIN
    RETURN QUERY
    SELECT 
        e.siren,
        e.nom_raison_sociale,
        e.ville,
        e.departement,
        e.libelle_naf,
        e.effectif,
        p.population
    FROM entreprises e
    LEFT JOIN population_communes p ON e.code_postal = p.code_postal
    WHERE e.statut = 'Actif'
        AND (p_departement IS NULL OR e.departement = p_departement)
        AND (p_code_naf IS NULL OR e.code_naf LIKE p_code_naf || '%')
        AND (p_effectif_min IS NULL OR e.tranche_effectif >= p_effectif_min)
        AND (p_ville IS NULL OR e.ville ILIKE '%' || p_ville || '%')
    ORDER BY p.population DESC NULLS LAST
    LIMIT p_limit;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION search_entreprises IS 'Search companies with filters and population context';

--------------------------------------------------------------------------------
-- Materialized View: Top Companies by Region
--------------------------------------------------------------------------------
CREATE MATERIALIZED VIEW IF NOT EXISTS top_entreprises_region AS
SELECT 
    e.region,
    p.nom_region,
    e.siren,
    e.nom_raison_sociale,
    e.libelle_naf,
    e.ville,
    e.effectif,
    p.population,
    ROW_NUMBER() OVER (PARTITION BY e.region ORDER BY 
        CASE e.tranche_effectif 
            WHEN '53' THEN 10000
            WHEN '52' THEN 5000
            WHEN '51' THEN 2000
            WHEN '42' THEN 1000
            WHEN '41' THEN 500
            WHEN '32' THEN 250
            WHEN '31' THEN 200
            WHEN '22' THEN 100
            WHEN '21' THEN 50
            WHEN '12' THEN 20
            WHEN '11' THEN 10
            WHEN '03' THEN 5
            WHEN '02' THEN 3
            WHEN '01' THEN 1
            ELSE 0
        END DESC
    ) as rang
FROM entreprises e
LEFT JOIN population_communes p ON e.code_postal = p.code_postal
WHERE e.statut = 'Actif'
    AND e.tranche_effectif IS NOT NULL
ORDER BY e.region, rang;

CREATE INDEX idx_top_entreprises_region ON top_entreprises_region(region, rang);

COMMENT ON MATERIALIZED VIEW top_entreprises_region IS 'Top companies by employee count in each region';

--------------------------------------------------------------------------------
-- Grant permissions
--------------------------------------------------------------------------------
GRANT USAGE ON SCHEMA opendata TO denodo;
GRANT SELECT ON ALL TABLES IN SCHEMA opendata TO denodo;
GRANT SELECT ON ALL VIEWS IN SCHEMA opendata TO denodo;
GRANT SELECT ON ALL MATERIALIZED VIEWS IN SCHEMA opendata TO denodo;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA opendata TO denodo;

-- Allow future objects
ALTER DEFAULT PRIVILEGES IN SCHEMA opendata GRANT SELECT ON TABLES TO denodo;
ALTER DEFAULT PRIVILEGES IN SCHEMA opendata GRANT SELECT ON VIEWS TO denodo;

--------------------------------------------------------------------------------
-- Completion message
--------------------------------------------------------------------------------
DO $$
BEGIN
    RAISE NOTICE 'OpenData schema created successfully!';
    RAISE NOTICE 'Tables: entreprises, population_communes';
    RAISE NOTICE 'Views: entreprises_population, stats_departement, top_entreprises_region';
    RAISE NOTICE 'Function: search_entreprises()';
    RAISE NOTICE 'Ready for data loading.';
END $$;
