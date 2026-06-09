#!/usr/bin/env python3
import sys
import os
import json
import bcrypt

def main():
    if len(sys.argv) < 3:
        print("Usage: python scripts/reset_password.py <username> <new_password>")
        sys.exit(1)

    username = sys.argv[1].strip().lower()
    new_password = sys.argv[2]

    # Resolve auth path relative to script location
    script_dir = os.path.dirname(os.path.abspath(__file__))
    repo_dir = os.path.dirname(script_dir)
    auth_file = os.path.join(repo_dir, "data", "auth.json")

    if not os.path.exists(auth_file):
        print(f"Error: {auth_file} not found. Ensure you are running from the repository root.")
        sys.exit(1)

    with open(auth_file, "r", encoding="utf-8") as f:
        data = json.load(f)

    if username not in data.get("users", {}):
        print(f"Error: User '{username}' not found in auth.json.")
        print(f"Available users: {', '.join(data.get('users', {}).keys())}")
        sys.exit(1)

    # Hash the new password using bcrypt
    hashed = bcrypt.hashpw(new_password.encode(), bcrypt.gensalt()).decode()
    data["users"][username]["password_hash"] = hashed

    with open(auth_file, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2)

    print(f"Successfully updated password for user '{username}'.")

if __name__ == "__main__":
    main()
