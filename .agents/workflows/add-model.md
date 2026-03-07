---
description: Create a new PormG.jl database model and migration
---

# Database Model Workflow

When the user asks to add a new database model or make schema changes, follow these steps to integrate with PormG.jl.

## 1. Define the Model
- Open the relevant models file (e.g., `src/models/user.jl` or `ext/NitroPormGExt/models.jl`).
- Define the `mutable struct` representing the table following PormG conventions.
- Ensure the struct is exported so it can be used in handlers.

## 2. Create the Migration
- Create a new migration file in the `migrations/` directory (e.g., `migrations/002_create_profiles.jl`).
- Write the `up()` function to create the table or modify the schema.
- Write the `down()` function to drop the table or revert the schema changes.

## 3. Update the Database Context
- If necessary, update the setup scripts to ensure the new migration is tracked.
- Ensure the handler functions (Step 1) use the `PormG.query` or `PormG.save!` APIs correctly within the handler context.

// turbo-all
## 4. Run Migrations & Test
Apply the migration to the local development database to verify the syntax is correct.
Command: `julia --project=. scripts/migrate.jl up`

Run the test suite.
Command: `julia --project=. -e "using Pkg; Pkg.test()"`
