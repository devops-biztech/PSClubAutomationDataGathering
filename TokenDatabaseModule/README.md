# TokenDatabaseModule

**TokenDatabaseModule** is a PowerShell 7 module designed to manage OAuth token storage and environment configuration using SQLite and `.env` files. It is part of an active GitHub repository and will continue to evolve as more functionality is added.

---

## 📦 Features

- ✅ Load environment variables from a `.env` file using `LoadEnv`
- ✅ Create a `.env` file with placeholders if one doesn't exist
- ✅ Validate required environment variables (`client_id`, `scope`, `database_location`)
- ✅ Initialize a SQLite database and create required tables
- ✅ Store and update the current refresh token
- ✅ Uses approved PowerShell verbs and modular design
- ✅ Automatically installs required modules (`PSSQLite`, `LoadEnv`) if missing

---

## 🛠 Installation

1. Clone the repository or download the module folder:

   ```bash
   git clone https://github.com/your-username/your-repo-name.git
   ```