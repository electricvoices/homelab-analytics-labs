# Homelab Analytics Labs

A collection of SQL-based analytics and data-quality exercises built from real Raspberry Pi and Pi-hole datasets.

[1. **Topics Covered**](#topics-covered) • [2. **Labs**](#labs) • [3. **Technologies**](#technologies) • [4. **Why I Built This**](#why-i-built-this) • [5. **Repository Structure**](#repository-structure) • [6. **Skills Demonstrated**](#skills-demonstrated)

## Topics Covered

- Data Profiling
- Data Cleaning
- Data Transformation
- Window Functions
- CTEs
- Statistical Analysis
- Reporting

## Labs

### DNS Profile

Uses exported Pi-hole DNS activity data to investigate query patterns, profile data quality issues, and prepare the dataset for reporting and visualization.

### Pi Health

Uses Raspberry Pi health-monitoring datasets to identify missing values, clean inconsistent records, and validate operational metrics before analysis. The focus is on transforming raw system-health data into a reliable dataset suitable for reporting and trend analysis.

### Pi Hourly

Works with time-series Raspberry Pi monitoring data to explore trends, hourly metrics, and operational behavior over time. The exercises demonstrate how SQL can be used to summarize and analyze sequential system-health measurements.

### Statistics

Applies aggregate SQL functions and statistical calculations to operational datasets. The exercises explore averages, minimums, maximums, counts, distributions, and summary metrics commonly used in reporting and analytics.

### Transformations

Converts raw operational data into reporting-ready datasets through a series of SQL transformations. These exercises focus on reshaping, enriching, and standardizing source data for downstream consumption and visualization.

### Power BI Dataset Preparation

Builds curated-datasets designed for dashboard development in Power BI. The exercises focus on preparing clean, structured data that can be used for KPI reporting, filtering, and interactive visualizations.

## Technologies

- PostgreSQL
- SQL
- Power BI
- CSV Datasets

## Why I Built This

While building and monitoring my homelab, I collected operational and DNS datasets that presented many of the same problems found in real-world data environments:

- Missing Values
- Duplicate Records
- Inconsistent Formats
- Raw Operational Logs
- Reporting Requirements

These labs were created to practice the process of profiling, cleaning, transforming, and analyzing data using PostgreSQL and SQL.

## Repository Structure

```text
homelab-analytics-labs/
├── dns_profile/
├── pi_health/
├── pi_hourly/
├── stats/
├── transform/
└── powerbi/
```

## Skills Demonstrated

### SQL

- CTEs
- Window Functions
- Aggregate Functions
- Data Profiling
- Data Transformation

### Analytics

- Data Cleaning
- Reporting
- Trend Analysis
- KPI Preparation

### Data Quality

- Duplicate Detection
- Validation
- Standardization
- Missing Value Handling
