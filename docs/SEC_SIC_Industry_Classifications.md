# SEC Standard Industrial Classification (SIC) Codes

> Complete reference guide for all SIC codes used in SEC EDGAR filings

> **Upstream SEC reference material.** This document describes the format SEC
> publishes, **not** the schema this project stores. It does not change when the
> pipeline changes. For what the pipeline actually holds — including the fields
> silver renames, such as `accepted` → `known_at` and `ddate` → `value_date` —
> see [`schema_overview.md`](schema_overview.md).


[![SEC](https://img.shields.io/badge/SEC-EDGAR-blue)](https://www.sec.gov/edgar)
[![SIC Codes](https://img.shields.io/badge/SIC-Industry_Classification-green)](https://www.sec.gov/search-filings/standard-industrial-classification-sic-code-list)

## 📋 Table of Contents

- [Overview](#overview)
- [Understanding SIC Codes](#understanding-sic-codes)
- [Division A: Agriculture, Forestry, and Fishing](#division-a-agriculture-forestry-and-fishing)
- [Division B: Mining](#division-b-mining)
- [Division C: Construction](#division-c-construction)
- [Division D: Manufacturing](#division-d-manufacturing)
- [Division E: Transportation, Communications, Electric, Gas, and Sanitary Services](#division-e-transportation-communications-electric-gas-and-sanitary-services)
- [Division F: Wholesale Trade](#division-f-wholesale-trade)
- [Division G: Retail Trade](#division-g-retail-trade)
- [Division H: Finance, Insurance, and Real Estate](#division-h-finance-insurance-and-real-estate)
- [Division I: Services](#division-i-services)
- [Division J: Public Administration](#division-j-public-administration)
- [SEC Office Assignments](#sec-office-assignments)
- [Usage Examples](#usage-examples)
- [Resources](#resources)

---

## Overview

The **Standard Industrial Classification (SIC)** system classifies companies by their primary business activity. In SEC EDGAR filings, SIC codes indicate a company's type of business and determine which SEC office reviews their filings.

### Key Facts

- **Format:** 4-digit numerical codes
- **Origin:** Developed in the 1930s by the U.S. Government
- **Last Revision:** 1987
- **Hierarchical Structure:** 
  - **First 2 digits:** Major industry group
  - **Third digit:** Industry subgroup  
  - **Fourth digit:** Specific industry

### Purpose in SEC Filings

1. **Company Classification:** Identifies primary business activity
2. **Filing Review Assignment:** Determines which SEC office reviews filings
3. **Data Analysis:** Enables industry-level analysis of financial data
4. **Research & Comparison:** Facilitates peer group identification

---

## Understanding SIC Codes

### Code Structure Example

**SIC 3674 - Semiconductors & Related Devices**

```
36   = Electronic & Other Equipment (Major Group)
367  = Electronic Components & Accessories (Industry Group)
3674 = Semiconductors & Related Devices (Specific Industry)
```

### Famous Company Examples

| Company | SIC Code | Industry |
|---------|----------|----------|
| Apple Inc. | 3571 | Electronic Computers |
| Tesla | 3711 | Motor Vehicles & Passenger Car Bodies |
| JPMorgan Chase | 6021 | National Commercial Banks |
| Amazon | 5961 | Catalog & Mail-Order Houses |
| ExxonMobil | 2911 | Petroleum Refining |

---
## Division A: Agriculture, Forestry, and Fishing

| SIC Code | Industry Title | SEC Office |
|----------|----------------|------------|
| 100 | Agricultural Production - Crops | Industrial Applications and Services |
| 200 | Agricultural Production - Livestock & Animal Specialties | Industrial Applications and Services |
| 700 | Agricultural Services | Industrial Applications and Services |
| 800 | Forestry | Industrial Applications and Services |
| 900 | Fishing, Hunting and Trapping | Industrial Applications and Services |

---

## Division B: Mining

### Metal Mining

| SIC Code | Industry Title | SEC Office |
|----------|----------------|------------|
| 1000 | Metal Mining | Energy & Transportation |
| 1040 | Gold and Silver Ores | Energy & Transportation |
| 1090 | Miscellaneous Metal Ores | Energy & Transportation |

### Coal Mining

| SIC Code | Industry Title | SEC Office |
|----------|----------------|------------|
| 1220 | Bituminous Coal & Lignite Mining | Energy & Transportation |
| 1221 | Bituminous Coal & Lignite Surface Mining | Energy & Transportation |

### Oil and Gas Extraction

| SIC Code | Industry Title | SEC Office |
|----------|----------------|------------|
| 1311 | Crude Petroleum & Natural Gas | Energy & Transportation |
| 1381 | Drilling Oil & Gas Wells | Energy & Transportation |
| 1382 | Oil & Gas Field Exploration Services | Energy & Transportation |
| 1389 | Oil & Gas Field Services, NEC | Energy & Transportation |

### Nonmetallic Minerals

| SIC Code | Industry Title | SEC Office |
|----------|----------------|------------|
| 1400 | Mining & Quarrying of Nonmetallic Minerals (No Fuels) | Energy & Transportation |

---

## Division C: Construction

| SIC Code | Industry Title | SEC Office |
|----------|----------------|------------|
| 1520 | General Building Contractors - Residential Buildings | Real Estate & Construction |
| 1531 | Operative Builders | Real Estate & Construction |
| 1540 | General Building Contractors - Nonresidential Buildings | Real Estate & Construction |
| 1600 | Heavy Construction Other Than Building Construction | Real Estate & Construction |
| 1623 | Water, Sewer, Pipeline, Communications & Power Line Construction | Real Estate & Construction |
| 1700 | Construction - Special Trade Contractors | Real Estate & Construction |
| 1731 | Electrical Work | Real Estate & Construction |

---

## Division D: Manufacturing

### Food and Kindred Products (20xx)

| SIC Code | Industry Title | SEC Office |
|----------|----------------|------------|
| 2000 | Food and Kindred Products | Manufacturing |
| 2011 | Meat Packing Plants | Manufacturing |
| 2013 | Sausages & Other Prepared Meat Products | Manufacturing |
| 2015 | Poultry Slaughtering and Processing | Manufacturing |
| 2020 | Dairy Products | Manufacturing |
| 2024 | Ice Cream & Frozen Desserts | Manufacturing |
| 2030 | Canned, Frozen & Preserved Fruit, Vegetables & Food Specialties | Manufacturing |
| 2033 | Canned Fruits, Vegetables, Preserves, Jams & Jellies | Manufacturing |
| 2040 | Grain Mill Products | Manufacturing |
| 2050 | Bakery Products | Manufacturing |
| 2052 | Cookies & Crackers | Manufacturing |
| 2060 | Sugar & Confectionery Products | Manufacturing |
| 2070 | Fats & Oils | Manufacturing |
| 2080 | Beverages | Manufacturing |
| 2082 | Malt Beverages | Manufacturing |
| 2086 | Bottled & Canned Soft Drinks & Carbonated Waters | Manufacturing |
| 2090 | Miscellaneous Food Preparations & Kindred Products | Manufacturing |
| 2092 | Prepared Fresh or Frozen Fish & Seafoods | Manufacturing |

### Tobacco Products (21xx)

| SIC Code | Industry Title | SEC Office |
|----------|----------------|------------|
| 2100 | Tobacco Products | Manufacturing |
| 2111 | Cigarettes | Manufacturing |

### Textile Mill Products (22xx)

| SIC Code | Industry Title | SEC Office |
|----------|----------------|------------|
| 2200 | Textile Mill Products | Manufacturing |
| 2211 | Broadwoven Fabric Mills, Cotton | Manufacturing |
| 2221 | Broadwoven Fabric Mills, Man Made Fiber & Silk | Manufacturing |
| 2250 | Knitting Mills | Manufacturing |
| 2253 | Knit Outerwear Mills | Manufacturing |
| 2273 | Carpets & Rugs | Manufacturing |

### Apparel (23xx)

| SIC Code | Industry Title | SEC Office |
|----------|----------------|------------|
| 2300 | Apparel & Other Finished Products of Fabrics & Similar Materials | Manufacturing |
| 2320 | Men's & Boys' Furnishings, Work Clothing, & Allied Garments | Manufacturing |
| 2330 | Women's, Misses', and Juniors Outerwear | Manufacturing |
| 2340 | Women's, Misses', Children's & Infants' Undergarments | Manufacturing |
| 2390 | Miscellaneous Fabricated Textile Products | Manufacturing |

### Lumber and Wood Products (24xx)

| SIC Code | Industry Title | SEC Office |
|----------|----------------|------------|
| 2400 | Lumber & Wood Products (No Furniture) | Manufacturing |
| 2421 | Sawmills & Planing Mills, General | Manufacturing |
| 2430 | Millwood, Veneer, Plywood, & Structural Wood Members | Manufacturing |
| 2451 | Mobile Homes | Manufacturing |
| 2452 | Prefabricated Wood Buildings & Components | Manufacturing |

### Furniture and Fixtures (25xx)

| SIC Code | Industry Title | SEC Office |
|----------|----------------|------------|
| 2510 | Household Furniture | Manufacturing |
| 2511 | Wood Household Furniture (No Upholstered) | Manufacturing |
| 2520 | Office Furniture | Manufacturing |
| 2522 | Office Furniture (No Wood) | Manufacturing |
| 2531 | Public Building & Related Furniture | Manufacturing |
| 2540 | Partitions, Shelving, Lockers, & Office & Store Fixtures | Manufacturing |
| 2590 | Miscellaneous Furniture & Fixtures | Manufacturing |

### Paper and Allied Products (26xx)

| SIC Code | Industry Title | SEC Office |
|----------|----------------|------------|
| 2600 | Papers & Allied Products | Manufacturing |
| 2611 | Pulp Mills | Manufacturing |
| 2621 | Paper Mills | Manufacturing |
| 2631 | Paperboard Mills | Manufacturing |
| 2650 | Paperboard Containers & Boxes | Manufacturing |
| 2670 | Converted Paper & Paperboard Products (No Containers/Boxes) | Manufacturing |
| 2673 | Plastics, Foil & Coated Paper Bags | Manufacturing |

### Printing and Publishing (27xx)

| SIC Code | Industry Title | SEC Office |
|----------|----------------|------------|
| 2711 | Newspapers: Publishing or Publishing & Printing | Manufacturing |
| 2721 | Periodicals: Publishing or Publishing & Printing | Manufacturing |
| 2731 | Books: Publishing or Publishing & Printing | Manufacturing |
| 2732 | Book Printing | Manufacturing |
| 2741 | Miscellaneous Publishing | Manufacturing |
| 2750 | Commercial Printing | Manufacturing |
| 2761 | Manifold Business Forms | Manufacturing |
| 2771 | Greeting Cards | Manufacturing |
| 2780 | Blankbooks, Looseleaf Binders & Bookbinding & Related Work | Manufacturing |
| 2790 | Service Industries for the Printing Trade | Manufacturing |

### Chemicals and Allied Products (28xx)

| SIC Code | Industry Title | SEC Office |
|----------|----------------|------------|
| 2800 | Chemicals & Allied Products | Industrial Applications and Services |
| 2810 | Industrial Inorganic Chemicals | Industrial Applications and Services |
| 2820 | Plastic Material, Synthetic Resin/Rubber, Cellulose (No Glass) | Industrial Applications and Services |
| 2821 | Plastic Materials, Synthetic Resins & Nonvulcanized Elastomers | Industrial Applications and Services |
| 2833 | Medicinal Chemicals & Botanical Products | Life Sciences |
| 2834 | Pharmaceutical Preparations | Life Sciences |
| 2835 | In Vitro & In Vivo Diagnostic Substances | Life Sciences |
| 2836 | Biological Products (No Diagnostic Substances) | Life Sciences |
| 2840 | Soap, Detergents, Cleaning Preparations, Perfumes, Cosmetics | Industrial Applications and Services |
| 2842 | Specialty Cleaning, Polishing and Sanitation Preparations | Industrial Applications and Services |
| 2844 | Perfumes, Cosmetics & Other Toilet Preparations | Industrial Applications and Services |
| 2851 | Paints, Varnishes, Lacquers, Enamels & Allied Products | Industrial Applications and Services |
| 2860 | Industrial Organic Chemicals | Industrial Applications and Services |
| 2870 | Agricultural Chemicals | Industrial Applications and Services |
| 2890 | Miscellaneous Chemical Products | Industrial Applications and Services |
| 2891 | Adhesives & Sealants | Industrial Applications and Services |

### Petroleum and Coal Products (29xx)

| SIC Code | Industry Title | SEC Office |
|----------|----------------|------------|
| 2911 | Petroleum Refining | Energy & Transportation |
| 2950 | Asphalt Paving & Roofing Materials | Energy & Transportation |
| 2990 | Miscellaneous Products of Petroleum & Coal | Energy & Transportation |

### Rubber and Miscellaneous Plastics Products (30xx)

| SIC Code | Industry Title | SEC Office |
|----------|----------------|------------|
| 3011 | Tires & Inner Tubes | Manufacturing |
| 3021 | Rubber & Plastics Footwear | Manufacturing |
| 3050 | Gaskets, Packing & Sealing Devices & Rubber & Plastics Hose | Manufacturing |
| 3060 | Fabricated Rubber Products, NEC | Manufacturing |
| 3080 | Miscellaneous Plastics Products | Industrial Applications and Services |
| 3081 | Unsupported Plastics Film & Sheet | Industrial Applications and Services |
| 3086 | Plastics Foam Products | Industrial Applications and Services |
| 3089 | Plastics Products, NEC | Industrial Applications and Services |

### Leather and Leather Products (31xx)

| SIC Code | Industry Title | SEC Office |
|----------|----------------|------------|
| 3100 | Leather & Leather Products | Manufacturing |
| 3140 | Footwear (No Rubber) | Manufacturing |

### Stone, Clay, Glass, and Concrete Products (32xx)

| SIC Code | Industry Title | SEC Office |
|----------|----------------|------------|
| 3211 | Flat Glass | Manufacturing |
| 3220 | Glass & Glassware, Pressed or Blown | Manufacturing |
| 3221 | Glass Containers | Manufacturing |
| 3231 | Glass Products, Made of Purchased Glass | Manufacturing |
| 3241 | Cement, Hydraulic | Manufacturing |
| 3250 | Structural Clay Products | Manufacturing |
| 3260 | Pottery & Related Products | Manufacturing |
| 3270 | Concrete, Gypsum & Plaster Products | Manufacturing |
| 3272 | Concrete Products, Except Block & Brick | Manufacturing |
| 3281 | Cut Stone & Stone Products | Manufacturing |
| 3290 | Abrasive, Asbestos & Miscellaneous Nonmetallic Mineral Products | Manufacturing |

### Primary Metal Industries (33xx)

| SIC Code | Industry Title | SEC Office |
|----------|----------------|------------|
| 3310 | Steel Works, Blast Furnaces & Rolling & Finishing Mills | Manufacturing |
| 3312 | Steel Works, Blast Furnaces & Rolling Mills (Coke Ovens) | Manufacturing |
| 3317 | Steel Pipe & Tubes | Manufacturing |
| 3320 | Iron & Steel Foundries | Manufacturing |
| 3330 | Primary Smelting & Refining of Nonferrous Metals | Manufacturing |
| 3334 | Primary Production of Aluminum | Manufacturing |
| 3341 | Secondary Smelting & Refining of Nonferrous Metals | Manufacturing |
| 3350 | Rolling Drawing & Extruding of Nonferrous Metals | Manufacturing |
| 3357 | Drawing & Insulating of Nonferrous Wire | Manufacturing |
| 3360 | Nonferrous Foundries (Castings) | Manufacturing |
| 3390 | Miscellaneous Primary Metal Products | Manufacturing |

### Fabricated Metal Products (34xx)

| SIC Code | Industry Title | SEC Office |
|----------|----------------|------------|
| 3411 | Metal Cans | Manufacturing |
| 3412 | Metal Shipping Barrels, Drums, Kegs & Pails | Manufacturing |
| 3420 | Cutlery, Handtools & General Hardware | Manufacturing |
| 3430 | Heating Equipment, Except Electric & Warm Air; & Plumbing Fixtures | Manufacturing |
| 3433 | Heating Equipment, Except Electric & Warm Air Furnaces | Manufacturing |
| 3440 | Fabricated Structural Metal Products | Manufacturing |
| 3442 | Metal Doors, Sash, Frames, Moldings & Trim | Manufacturing |
| 3443 | Fabricated Plate Work (Boiler Shops) | Manufacturing |
| 3444 | Sheet Metal Work | Manufacturing |
| 3448 | Prefabricated Metal Buildings & Components | Manufacturing |
| 3451 | Screw Machine Products | Manufacturing |
| 3452 | Bolts, Nuts, Screws, Rivets & Washers | Manufacturing |
| 3460 | Metal Forgings & Stampings | Manufacturing |
| 3470 | Coating, Engraving & Allied Services | Manufacturing |
| 3480 | Ordnance & Accessories (No Vehicles/Guided Missiles) | Manufacturing |
| 3490 | Miscellaneous Fabricated Metal Products | Manufacturing |

### Industrial and Commercial Machinery and Computer Equipment (35xx)

| SIC Code | Industry Title | SEC Office |
|----------|----------------|------------|
| 3510 | Engines & Turbines | Technology |
| 3523 | Farm Machinery & Equipment | Technology |
| 3524 | Lawn & Garden Tractors & Home Lawn & Gardens Equipment | Technology |
| 3530 | Construction, Mining & Materials Handling Machinery & Equipment | Technology |
| 3531 | Construction Machinery & Equipment | Technology |
| 3532 | Mining Machinery & Equipment (No Oil & Gas Field Machinery & Equipment) | Technology |
| 3533 | Oil & Gas Field Machinery & Equipment | Energy & Transportation |
| 3537 | Industrial Trucks, Tractors, Trailers & Stackers | Technology |
| 3540 | Metalworking Machinery & Equipment | Technology |
| 3541 | Machine Tools, Metal Cutting Types | Technology |
| 3550 | Special Industry Machinery (No Metalworking Machinery) | Technology |
| 3555 | Printing Trades Machinery & Equipment | Technology |
| 3559 | Special Industry Machinery, NEC | Technology |
| 3560 | General Industrial Machinery & Equipment | Technology |
| 3561 | Pumps & Pumping Equipment | Technology |
| 3562 | Ball & Roller Bearings | Technology |
| 3564 | Industrial & Commercial Fans & Blowers & Air Purifying Equipment | Technology |
| 3567 | Industrial Process Furnaces & Ovens | Technology |
| 3569 | General Industrial Machinery & Equipment, NEC | Technology |
| 3570 | Computer & Office Equipment | Technology |
| 3571 | Electronic Computers | Technology |
| 3572 | Computer Storage Devices | Technology |
| 3575 | Computer Terminals | Technology |
| 3576 | Computer Communications Equipment | Technology |
| 3577 | Computer Peripheral Equipment, NEC | Technology |
| 3578 | Calculating & Accounting Machines (No Electronic Computers) | Technology |
| 3579 | Office Machines, NEC | Technology |
| 3580 | Refrigeration & Service Industry Machinery | Technology |
| 3585 | Air-Conditioning & Warm Air Heating Equipment & Commercial & Industrial Refrigeration Equipment | Technology |
| 3590 | Miscellaneous Industrial & Commercial Machinery & Equipment | Technology |

### Electronic and Other Electrical Equipment (36xx)

| SIC Code | Industry Title | SEC Office |
|----------|----------------|------------|
| 3600 | Electronic & Other Electrical Equipment (No Computer Equipment) | Manufacturing |
| 3612 | Power, Distribution & Specialty Transformers | Manufacturing |
| 3613 | Switchgear & Switchboard Apparatus | Manufacturing |
| 3620 | Electrical Industrial Apparatus | Manufacturing |
| 3621 | Motors & Generators | Manufacturing |
| 3630 | Household Appliances | Manufacturing |
| 3634 | Electric Housewares & Fans | Manufacturing |
| 3640 | Electric Lighting & Wiring Equipment | Manufacturing |
| 3651 | Household Audio & Video Equipment | Manufacturing |
| 3652 | Phonograph Records & Prerecorded Audio Tapes & Disks | Manufacturing |
| 3661 | Telephone & Telegraph Apparatus | Manufacturing |
| 3663 | Radio & TV Broadcasting & Communications Equipment | Manufacturing |
| 3669 | Communications Equipment, NEC | Manufacturing |
| 3670 | Electronic Components & Accessories | Manufacturing |
| 3672 | Printed Circuit Boards | Manufacturing |
| 3674 | Semiconductors & Related Devices | Manufacturing |
| 3677 | Electronic Coils, Transformers & Other Inductors | Manufacturing |
| 3678 | Electronic Connectors | Manufacturing |
| 3679 | Electronic Components, NEC | Manufacturing |
| 3690 | Miscellaneous Electrical Machinery, Equipment & Supplies | Manufacturing |
| 3695 | Magnetic & Optical Recording Media | Manufacturing |

### Transportation Equipment (37xx)

| SIC Code | Industry Title | SEC Office |
|----------|----------------|------------|
| 3711 | Motor Vehicles & Passenger Car Bodies | Manufacturing |
| 3713 | Truck & Bus Bodies | Manufacturing |
| 3714 | Motor Vehicle Parts & Accessories | Manufacturing |
| 3715 | Truck Trailers | Manufacturing |
| 3716 | Motor Homes | Manufacturing |
| 3720 | Aircraft & Parts | Manufacturing |
| 3721 | Aircraft | Manufacturing |
| 3724 | Aircraft Engines & Engine Parts | Manufacturing |
| 3728 | Aircraft Parts & Auxiliary Equipment, NEC | Manufacturing |
| 3730 | Ship & Boat Building & Repairing | Manufacturing |
| 3743 | Railroad Equipment | Manufacturing |
| 3751 | Motorcycles, Bicycles & Parts | Manufacturing |
| 3760 | Guided Missiles & Space Vehicles & Parts | Manufacturing |
| 3790 | Miscellaneous Transportation Equipment | Manufacturing |

### Measuring, Analyzing, and Controlling Instruments (38xx)

| SIC Code | Industry Title | SEC Office |
|----------|----------------|------------|
| 3812 | Search, Detection, Navigation, Guidance, Aeronautical Systems | Manufacturing |
| 3821 | Laboratory Apparatus & Furniture | Industrial Applications and Services |
| 3822 | Auto Controls for Regulating Residential & Commercial Environments | Industrial Applications and Services |
| 3823 | Industrial Instruments for Measurement, Display, and Control | Industrial Applications and Services |
| 3824 | Totalizing Fluid Meters & Counting Devices | Industrial Applications and Services |
| 3825 | Instruments for Measuring & Testing of Electricity & Electrical Signals | Industrial Applications and Services |
| 3826 | Laboratory Analytical Instruments | Industrial Applications and Services |
| 3827 | Optical Instruments & Lenses | Industrial Applications and Services |
| 3829 | Measuring & Controlling Devices, NEC | Industrial Applications and Services |
| 3841 | Surgical & Medical Instruments & Apparatus | Industrial Applications and Services |
| 3842 | Orthopedic, Prosthetic & Surgical Appliances & Supplies | Industrial Applications and Services |
| 3843 | Dental Equipment & Supplies | Industrial Applications and Services |
| 3844 | X-Ray Apparatus & Tubes & Related Irradiation Apparatus | Industrial Applications and Services |
| 3845 | Electromedical & Electrotherapeutic Apparatus | Industrial Applications and Services |
| 3851 | Ophthalmic Goods | Industrial Applications and Services |
| 3861 | Photographic Equipment & Supplies | Industrial Applications and Services |
| 3873 | Watches, Clocks, Clockwork Operated Devices/Parts | Industrial Applications and Services |

### Miscellaneous Manufacturing Industries (39xx)

| SIC Code | Industry Title | SEC Office |
|----------|----------------|------------|
| 3910 | Jewelry, Silverware & Plated Ware | Manufacturing |
| 3911 | Jewelry, Precious Metal | Manufacturing |
| 3931 | Musical Instruments | Manufacturing |
| 3942 | Dolls & Stuffed Toys | Manufacturing |
| 3944 | Games, Toys & Children's Vehicles (No Dolls & Bicycles) | Manufacturing |
| 3949 | Sporting & Athletic Goods, NEC | Manufacturing |
| 3950 | Pens, Pencils & Other Artists' Materials | Manufacturing |
| 3960 | Costume Jewelry & Novelties | Manufacturing |
| 3990 | Miscellaneous Manufacturing Industries | Manufacturing |

---
## Division E: Transportation, Communications, Electric, Gas, and Sanitary Services

### Transportation (40xx-47xx)

| SIC Code | Industry Title | SEC Office |
|----------|----------------|------------|
| 4011 | Railroads, Line-Haul Operating | Energy & Transportation |
| 4013 | Railroad Switching & Terminal Establishments | Energy & Transportation |
| 4100 | Local & Suburban Transit & Interurban Highway Passenger Transportation | Energy & Transportation |
| 4210 | Trucking & Courier Services (No Air) | Energy & Transportation |
| 4213 | Trucking (No Local) | Energy & Transportation |
| 4220 | Public Warehousing & Storage | Energy & Transportation |
| 4231 | Terminal Maintenance Facilities for Motor Freight Transport | Energy & Transportation |
| 4400 | Water Transportation | Energy & Transportation |
| 4412 | Deep Sea Foreign Transportation of Freight | Energy & Transportation |
| 4512 | Air Transportation, Scheduled | Energy & Transportation |
| 4513 | Air Courier Services | Energy & Transportation |
| 4522 | Air Transportation, Nonscheduled | Energy & Transportation |
| 4581 | Airports, Flying Fields & Airport Terminal Services | Energy & Transportation |
| 4610 | Pipe Lines (No Natural Gas) | Energy & Transportation |
| 4700 | Transportation Services | Energy & Transportation |
| 4731 | Arrangement of Transportation of Freight & Cargo | Energy & Transportation |

### Communications (48xx)

| SIC Code | Industry Title | SEC Office |
|----------|----------------|------------|
| 4812 | Radiotelephone Communications | Technology |
| 4813 | Telephone Communications (No Radiotelephone) | Technology |
| 4822 | Telegraph & Other Message Communications | Technology |
| 4832 | Radio Broadcasting Stations | Technology |
| 4833 | Television Broadcasting Stations | Technology |
| 4841 | Cable & Other Pay Television Services | Technology |
| 4899 | Communications Services, NEC | Technology |

### Electric, Gas, and Sanitary Services (49xx)

| SIC Code | Industry Title | SEC Office |
|----------|----------------|------------|
| 4900 | Electric, Gas & Sanitary Services | Energy & Transportation |
| 4911 | Electric Services | Energy & Transportation |
| 4922 | Natural Gas Transmission | Energy & Transportation |
| 4923 | Natural Gas Transmission & Distribution | Energy & Transportation |
| 4924 | Natural Gas Distribution | Energy & Transportation |
| 4931 | Electric & Other Services Combined | Energy & Transportation |
| 4932 | Gas & Other Services Combined | Energy & Transportation |
| 4941 | Water Supply | Energy & Transportation |
| 4950 | Sanitary Services | Energy & Transportation |
| 4953 | Refuse Systems | Energy & Transportation |
| 4955 | Hazardous Waste Management | Energy & Transportation |
| 4961 | Steam & Air-Conditioning Supply | Energy & Transportation |
| 4991 | Cogeneration Services & Small Power Producers | Energy & Transportation |

---

## Division F: Wholesale Trade

| SIC Code | Industry Title | SEC Office |
|----------|----------------|------------|
| 5000 | Wholesale - Durable Goods | Trade & Services |
| 5010 | Wholesale - Motor Vehicles & Motor Vehicle Parts & Supplies | Trade & Services |
| 5013 | Wholesale - Motor Vehicle Supplies & New Parts | Trade & Services |
| 5020 | Wholesale - Furniture & Home Furnishings | Trade & Services |
| 5030 | Wholesale - Lumber & Other Construction Materials | Trade & Services |
| 5031 | Wholesale - Lumber, Plywood, Millwork & Wood Panels | Trade & Services |
| 5040 | Wholesale - Professional & Commercial Equipment & Supplies | Trade & Services |
| 5045 | Wholesale - Computers & Peripheral Equipment & Software | Trade & Services |
| 5047 | Wholesale - Medical, Dental & Hospital Equipment & Supplies | Trade & Services |
| 5050 | Wholesale - Metals & Minerals (No Petroleum) | Trade & Services |
| 5051 | Wholesale - Metals Service Centers & Offices | Trade & Services |
| 5063 | Wholesale - Electrical Apparatus & Equipment, Wiring Supplies | Trade & Services |
| 5064 | Wholesale - Electrical Appliances, TV & Radio Sets | Trade & Services |
| 5065 | Wholesale - Electronic Parts & Equipment, NEC | Trade & Services |
| 5070 | Wholesale - Hardware & Plumbing & Heating Equipment & Supplies | Trade & Services |
| 5072 | Wholesale - Hardware | Trade & Services |
| 5080 | Wholesale - Machinery, Equipment & Supplies | Trade & Services |
| 5082 | Wholesale - Construction & Mining (No Petroleum) Machinery & Equipment | Trade & Services |
| 5084 | Wholesale - Industrial Machinery & Equipment | Trade & Services |
| 5090 | Wholesale - Miscellaneous Durable Goods | Trade & Services |
| 5094 | Wholesale - Jewelry, Watches, Precious Stones & Metals | Trade & Services |
| 5099 | Wholesale - Durable Goods, NEC | Trade & Services |
| 5110 | Wholesale - Paper & Paper Products | Trade & Services |
| 5122 | Wholesale - Drugs, Proprietaries & Druggists' Sundries | Trade & Services |
| 5130 | Wholesale - Apparel, Piece Goods & Notions | Trade & Services |
| 5140 | Wholesale - Groceries & Related Products | Trade & Services |
| 5141 | Wholesale - Groceries, General Line | Trade & Services |
| 5150 | Wholesale - Farm Product Raw Materials | Trade & Services |
| 5160 | Wholesale - Chemicals & Allied Products | Trade & Services |
| 5171 | Wholesale - Petroleum Bulk Stations & Terminals | Trade & Services |
| 5172 | Wholesale - Petroleum & Petroleum Products (No Bulk Stations) | Trade & Services |
| 5180 | Wholesale - Beer, Wine & Distilled Alcoholic Beverages | Trade & Services |
| 5190 | Wholesale - Miscellaneous Nondurable Goods | Trade & Services |

---

## Division G: Retail Trade

| SIC Code | Industry Title | SEC Office |
|----------|----------------|------------|
| 5200 | Retail - Building Materials, Hardware, Garden Supply | Trade & Services |
| 5211 | Retail - Lumber & Other Building Materials Dealers | Trade & Services |
| 5271 | Retail - Mobile Home Dealers | Trade & Services |
| 5311 | Retail - Department Stores | Trade & Services |
| 5331 | Retail - Variety Stores | Trade & Services |
| 5399 | Retail - Miscellaneous General Merchandise Stores | Trade & Services |
| 5400 | Retail - Food Stores | Trade & Services |
| 5411 | Retail - Grocery Stores | Trade & Services |
| 5412 | Retail - Convenience Stores | Trade & Services |
| 5500 | Retail - Auto Dealers & Gasoline Stations | Trade & Services |
| 5531 | Retail - Auto & Home Supply Stores | Trade & Services |
| 5600 | Retail - Apparel & Accessory Stores | Trade & Services |
| 5621 | Retail - Women's Clothing Stores | Trade & Services |
| 5651 | Retail - Family Clothing Stores | Trade & Services |
| 5661 | Retail - Shoe Stores | Trade & Services |
| 5700 | Retail - Home Furniture, Furnishings & Equipment Stores | Trade & Services |
| 5712 | Retail - Furniture Stores | Trade & Services |
| 5731 | Retail - Radio, TV & Consumer Electronics Stores | Trade & Services |
| 5734 | Retail - Computer & Computer Software Stores | Trade & Services |
| 5735 | Retail - Record & Prerecorded Tape Stores | Trade & Services |
| 5810 | Retail - Eating & Drinking Places | Trade & Services |
| 5812 | Retail - Eating Places | Trade & Services |
| 5900 | Retail - Miscellaneous Retail | Trade & Services |
| 5912 | Retail - Drug Stores and Proprietary Stores | Trade & Services |
| 5940 | Retail - Miscellaneous Shopping Goods Stores | Trade & Services |
| 5944 | Retail - Jewelry Stores | Trade & Services |
| 5945 | Retail - Hobby, Toy & Game Shops | Trade & Services |
| 5960 | Retail - Nonstore Retailers | Trade & Services |
| 5961 | Retail - Catalog & Mail-Order Houses | Trade & Services |
| 5990 | Retail - Retail Stores, NEC | Trade & Services |

---

## Division H: Finance, Insurance, and Real Estate

### Banking (60xx-61xx)

| SIC Code | Industry Title | SEC Office |
|----------|----------------|------------|
| 6021 | National Commercial Banks | Finance |
| 6022 | State Commercial Banks | Finance |
| 6029 | Commercial Banks, NEC | Finance |
| 6035 | Savings Institution, Federally Chartered | Finance |
| 6036 | Savings Institutions, Not Federally Chartered | Finance |
| 6099 | Functions Related to Depository Banking, NEC | Finance |
| 6111 | Federal & Federally-Sponsored Credit Agencies | Finance |
| 6141 | Personal Credit Institutions | Finance |
| 6153 | Short-Term Business Credit Institutions | Finance |
| 6159 | Miscellaneous Business Credit Institution | Finance |
| 6162 | Mortgage Bankers & Loan Correspondents | Finance |
| 6163 | Loan Brokers | Finance |
| 6172 | Finance Lessors | Finance |
| 6189 | Asset-Backed Securities | Structured Finance |
| 6199 | Finance Services | Finance or Crypto Assets |

### Securities and Commodities (62xx)

| SIC Code | Industry Title | SEC Office |
|----------|----------------|------------|
| 6200 | Security & Commodity Brokers, Dealers, Exchanges & Services | Crypto Assets |
| 6211 | Security Brokers, Dealers & Flotation Companies | Finance or Crypto Assets |
| 6221 | Commodity Contracts Brokers & Dealers | Crypto Assets |
| 6282 | Investment Advice | Finance |

### Insurance (63xx-64xx)

| SIC Code | Industry Title | SEC Office |
|----------|----------------|------------|
| 6311 | Life Insurance | Finance |
| 6321 | Accident & Health Insurance | Finance |
| 6324 | Hospital & Medical Service Plans | Finance |
| 6331 | Fire, Marine & Casualty Insurance | Finance |
| 6351 | Surety Insurance | Finance |
| 6361 | Title Insurance | Finance |
| 6399 | Insurance Carriers, NEC | Finance |
| 6411 | Insurance Agents, Brokers & Service | Finance |

### Real Estate (65xx)

| SIC Code | Industry Title | SEC Office |
|----------|----------------|------------|
| 6500 | Real Estate | Real Estate & Construction |
| 6510 | Real Estate Operators (No Developers) & Lessors | Real Estate & Construction |
| 6512 | Operators of Nonresidential Buildings | Real Estate & Construction |
| 6513 | Operators of Apartment Buildings | Real Estate & Construction |
| 6519 | Lessors of Real Property, NEC | Real Estate & Construction |
| 6531 | Real Estate Agents & Managers (For Others) | Real Estate & Construction |
| 6532 | Real Estate Dealers (For Their Own Account) | Real Estate & Construction |
| 6552 | Land Subdividers & Developers (No Cemeteries) | Real Estate & Construction |

### Holding and Investment Companies (67xx)

| SIC Code | Industry Title | SEC Office |
|----------|----------------|------------|
| 6770 | Blank Checks | Real Estate & Construction |
| 6792 | Oil Royalty Traders | Energy & Transportation |
| 6794 | Patent Owners & Lessors | Real Estate & Construction |
| 6795 | Mineral Royalty Traders | Energy & Transportation |
| 6798 | Real Estate Investment Trusts | Real Estate & Construction |
| 6799 | Investors, NEC | Real Estate & Construction |

---

## Division I: Services

### Hotels and Lodging (70xx)

| SIC Code | Industry Title | SEC Office |
|----------|----------------|------------|
| 7000 | Hotels, Rooming Houses, Camps & Other Lodging Places | Real Estate & Construction |
| 7011 | Hotels & Motels | Real Estate & Construction |

### Personal Services (72xx)

| SIC Code | Industry Title | SEC Office |
|----------|----------------|------------|
| 7200 | Services - Personal Services | Trade & Services |

### Business Services (73xx)

| SIC Code | Industry Title | SEC Office |
|----------|----------------|------------|
| 7310 | Services - Advertising | Trade & Services |
| 7311 | Services - Advertising Agencies | Trade & Services |
| 7320 | Services - Consumer Credit Reporting, Collection Agencies | Trade & Services |
| 7330 | Services - Mailing, Reproduction, Commercial Art & Photography | Trade & Services |
| 7331 | Services - Direct Mail Advertising Services | Trade & Services |
| 7340 | Services - To Dwellings & Other Buildings | Trade & Services |
| 7350 | Services - Miscellaneous Equipment Rental & Leasing | Trade & Services |
| 7359 | Services - Equipment Rental & Leasing, NEC | Trade & Services |
| 7361 | Services - Employment Agencies | Trade & Services |
| 7363 | Services - Help Supply Services | Trade & Services |
| 7370 | Services - Computer Programming, Data Processing, ETC. | Technology |
| 7371 | Services - Computer Programming Services | Technology |
| 7372 | Services - Prepackaged Software | Technology |
| 7373 | Services - Computer Integrated Systems Design | Technology |
| 7374 | Services - Computer Processing & Data Preparation | Technology |
| 7377 | Services - Computer Rental & Leasing | Trade & Services |
| 7380 | Services - Miscellaneous Business Services | Trade & Services |
| 7381 | Services - Detective, Guard & Armored Car Services | Trade & Services |
| 7384 | Services - Photofinishing Laboratories | Trade & Services |
| 7385 | Services - Telephone Interconnect Systems | Trade & Services |
| 7389 | Services - Business Services, NEC | Trade & Services or Energy & Transportation |

### Automotive Services (75xx)

| SIC Code | Industry Title | SEC Office |
|----------|----------------|------------|
| 7500 | Services - Automotive Repair, Services & Parking | Trade & Services |
| 7510 | Services - Auto Rental & Leasing (No Drivers) | Trade & Services |

### Miscellaneous Repair Services (76xx)

| SIC Code | Industry Title | SEC Office |
|----------|----------------|------------|
| 7600 | Services - Miscellaneous Repair Services | Trade & Services |

### Motion Pictures (78xx)

| SIC Code | Industry Title | SEC Office |
|----------|----------------|------------|
| 7812 | Services - Motion Picture & Video Tape Production | Trade & Services |
| 7819 | Services - Allied to Motion Picture Production | Trade & Services |
| 7822 | Services - Motion Picture & Video Tape Distribution | Trade & Services |
| 7829 | Services - Allied to Motion Picture Distribution | Trade & Services |
| 7830 | Services - Motion Picture Theaters | Trade & Services |
| 7841 | Services - Video Tape Rental | Trade & Services |

### Amusement and Recreation (79xx)

| SIC Code | Industry Title | SEC Office |
|----------|----------------|------------|
| 7900 | Services - Amusement & Recreation Services | Trade & Services |
| 7948 | Services - Racing, Including Track Operation | Trade & Services |
| 7990 | Services - Miscellaneous Amusement & Recreation | Trade & Services |
| 7997 | Services - Membership Sports & Recreation Clubs | Trade & Services |

### Health Services (80xx)

| SIC Code | Industry Title | SEC Office |
|----------|----------------|------------|
| 8000 | Services - Health Services | Industrial Applications and Services |
| 8011 | Services - Offices & Clinics of Doctors of Medicine | Industrial Applications and Services |
| 8050 | Services - Nursing & Personal Care Facilities | Industrial Applications and Services |
| 8051 | Services - Skilled Nursing Care Facilities | Industrial Applications and Services |
| 8060 | Services - Hospitals | Industrial Applications and Services |
| 8062 | Services - General Medical & Surgical Hospitals, NEC | Industrial Applications and Services |
| 8071 | Services - Medical Laboratories | Industrial Applications and Services |
| 8082 | Services - Home Health Care Services | Industrial Applications and Services |
| 8090 | Services - Miscellaneous Health & Allied Services, NEC | Industrial Applications and Services |
| 8093 | Services - Specialty Outpatient Facilities, NEC | Industrial Applications and Services |

### Legal Services (81xx)

| SIC Code | Industry Title | SEC Office |
|----------|----------------|------------|
| 8111 | Services - Legal Services | Trade & Services |

### Educational Services (82xx)

| SIC Code | Industry Title | SEC Office |
|----------|----------------|------------|
| 8200 | Services - Educational Services | Trade & Services |

### Social Services (83xx)

| SIC Code | Industry Title | SEC Office |
|----------|----------------|------------|
| 8300 | Services - Social Services | Industrial Applications and Services |
| 8351 | Services - Child Day Care Services | Trade & Services |

### Membership Organizations (86xx)

| SIC Code | Industry Title | SEC Office |
|----------|----------------|------------|
| 8600 | Services - Membership Organizations | Trade & Services |

### Engineering, Accounting, Research, Management (87xx)

| SIC Code | Industry Title | SEC Office |
|----------|----------------|------------|
| 8700 | Services - Engineering, Accounting, Research, Management | Trade & Services |
| 8711 | Services - Engineering Services | Trade & Services |
| 8731 | Services - Commercial Physical & Biological Research | Industrial Applications and Services |
| 8734 | Services - Testing Laboratories | Industrial Applications and Services |
| 8741 | Services - Management Services | Trade & Services |
| 8742 | Services - Management Consulting Services | Trade & Services |
| 8744 | Services - Facilities Support Management Services | Trade & Services |

### Special Classification Codes (88xx-89xx)

| SIC Code | Industry Title | SEC Office |
|----------|----------------|------------|
| 8880 | American Depositary Receipts | International Corp Finance |
| 8888 | Foreign Governments | International Corp Finance |
| 8900 | Services - Services, NEC | Trade & Services |

---

## Division J: Public Administration

| SIC Code | Industry Title | SEC Office |
|----------|----------------|------------|
| 9721 | International Affairs | International Corp Finance |
| 9995 | Non-Operating Establishments | Real Estate & Construction |

---

## SEC Office Assignments

The SEC uses SIC codes to assign filing review responsibility to different offices:

| SEC Office | Primary Industry Coverage | Example SIC Codes |
|------------|---------------------------|-------------------|
| **Energy & Transportation** | Energy, mining, oil & gas, transportation, utilities | 1000-1499, 2911, 4011-4991, 6792, 6795 |
| **Finance** | Banking, insurance, investment services | 6021-6411 |
| **Crypto Assets** | Digital assets, cryptocurrency, blockchain | 6199, 6200-6221 |
| **Structured Finance** | Asset-backed securities, complex instruments | 6189 |
| **Industrial Applications and Services** | Chemicals, plastics, instruments, healthcare | 2800-2890, 3080-3089, 3821-3873, 8000-8093 |
| **Life Sciences** | Pharmaceuticals, biotech, medical devices | 2833-2836 |
| **Manufacturing** | General manufacturing, electronics, consumer goods | 2000-2111, 3000-3990 |
| **Real Estate & Construction** | Real estate, construction, lodging, SPACs | 1520-1731, 6500-6799, 7000-7011, 9995 |
| **Technology** | Software, hardware, communications, IT services | 3510-3579, 4812-4899, 7370-7374 |
| **Trade & Services** | Wholesale, retail, business services | 5000-5990, 7200-8900 |
| **International Corp Finance** | Foreign issuers, ADRs, cross-border | 8880, 8888, 9721 |

---

## Usage Examples

### Finding SIC Code in SQL

```sql
-- Get companies by SIC code
SELECT name, cik, sic
FROM SUB
WHERE sic = 3571  -- Electronic Computers
AND fy = 2024
ORDER BY name;

-- Get all tech companies (SIC 35xx and 73xx)
SELECT DISTINCT name, sic
FROM SUB
WHERE (sic BETWEEN 3500 AND 3599)  -- Computer/Tech Hardware
   OR (sic BETWEEN 7370 AND 7379)  -- Software/Services
ORDER BY sic, name;

-- Count filings by industry
SELECT sic, COUNT(*) as filing_count
FROM SUB
WHERE fy = 2024
GROUP BY sic
ORDER BY filing_count DESC
LIMIT 20;
```

### Python Usage

```python
import pandas as pd

# Read SEC dataset
df = pd.read_csv('sub.txt', sep='\t')

# Filter by SIC code
pharma = df[df['sic'] == 2834]  # Pharmaceutical Preparations

# Group by industry (first 2 digits)
df['industry_group'] = df['sic'] // 100
industry_counts = df.groupby('industry_group').size()

# Get major industry group
def get_major_group(sic):
    if 100 <= sic <= 999:
        return "Agriculture, Forestry, Fishing"
    elif 1000 <= sic <= 1499:
        return "Mining"
    elif 1500 <= sic <= 1799:
        return "Construction"
    elif 2000 <= sic <= 3999:
        return "Manufacturing"
    elif 4000 <= sic <= 4999:
        return "Transportation & Utilities"
    elif 5000 <= sic <= 5199:
        return "Wholesale Trade"
    elif 5200 <= sic <= 5999:
        return "Retail Trade"
    elif 6000 <= sic <= 6799:
        return "Finance, Insurance, Real Estate"
    elif 7000 <= sic <= 8999:
        return "Services"
    else:
        return "Other"

df['major_group'] = df['sic'].apply(get_major_group)
```

### Common Industry Queries

**Technology Companies:**
```sql
WHERE sic IN (3571, 3572, 3576, 3577, 7370, 7371, 7372, 7373)
```

**Energy Companies:**
```sql
WHERE sic IN (1311, 2911, 4911, 4922, 4923, 4924)
```

**Financial Services:**
```sql
WHERE sic BETWEEN 6000 AND 6799
```

**Healthcare:**
```sql
WHERE sic IN (2833, 2834, 2835, 2836, 8000, 8011, 8060, 8062)
```

**Retail:**
```sql
WHERE sic BETWEEN 5200 AND 5999
```

---

## Resources

### Official Documentation

- 📄 [SEC SIC Code List](https://www.sec.gov/search-filings/standard-industrial-classification-sic-code-list)
- 📚 [OSHA SIC Manual](https://www.osha.gov/data/sic-manual)
- 🔍 [OSHA SIC Search](https://www.osha.gov/data/sic-search)

### Related Systems

- **NAICS** (North American Industry Classification System): Replaced SIC in 1997 for most government uses
- **NAICS** uses 6-digit codes vs SIC's 4-digit codes
- Many companies still report both SIC and NAICS codes

### Key Differences: SIC vs NAICS

| Feature | SIC | NAICS |
|---------|-----|-------|
| Digits | 4 | 6 |
| Last Updated | 1987 | Regularly (every 5 years) |
| Coverage | US-focused | North America (US, Canada, Mexico) |
| Service Industries | Limited | Expanded |
| Technology | Outdated | Modern |
| SEC Usage | ✅ Primary | ❌ Not used |

### Important Notes

- SIC codes are **self-classified** by companies
- Companies may change SIC codes as their business evolves
- A company can have only **one primary SIC code**
- SIC codes in SEC data reflect assignment **at time of filing**
- Some SIC codes end in "9" = "Not Elsewhere Classified" (NEC)

---

## Quick Reference by Major Group

| Range | Division | Examples |
|-------|----------|----------|
| 0100-0999 | A - Agriculture | Crops, Livestock, Forestry, Fishing |
| 1000-1499 | B - Mining | Metal, Coal, Oil & Gas |
| 1500-1799 | C - Construction | Building, Heavy Construction |
| 2000-3999 | D - Manufacturing | Food, Chemicals, Electronics, Vehicles |
| 4000-4999 | E - Transport & Utilities | Transportation, Communications, Energy |
| 5000-5199 | F - Wholesale | Durable & Nondurable Goods |
| 5200-5999 | G - Retail | Department Stores, Food, Auto, Apparel |
| 6000-6799 | H - Finance & Real Estate | Banking, Insurance, Real Estate |
| 7000-8999 | I - Services | Hotels, Business, Health, Education |
| 9000-9999 | J - Public Administration | Government, International |

---

**Last Updated:** December 2024 (based on SEC official SIC code list)

**Version:** 1.0.0

---

## Contributing

Found an error or want to add industry insights? Contributions welcome!

1. Check existing issues
2. Submit detailed pull requests
3. Follow markdown formatting standards

---

## License

This documentation is provided as-is for educational and research purposes. SEC data is public domain.
