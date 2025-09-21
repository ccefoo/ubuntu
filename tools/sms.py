import subprocess
import json
import sys
import os
from datetime import datetime
import re

# Define the path for the JSON file
JSON_FILE = "sms.json"

def run_command(command):
    """Executes a shell command and returns its output, or None if an error occurs."""
    try:
        result = subprocess.run(command, capture_output=True, text=True, check=True, shell=False)
        return result.stdout.strip()
    except (subprocess.CalledProcessError, FileNotFoundError) as e:
        # Don't print error for "not found" as it can be an expected outcome
        if "No such file or directory" not in str(e) and "not found" not in str(e):
             print(f"Command failed: {' '.join(command)}\nError: {e}")
        return None

def get_modem_path():
    """Gets the path of the first modem managed by ModemManager."""
    output = run_command(['mmcli', '-L'])
    if output:
        for line in output.splitlines():
            if 'Modem' in line:
                match = re.search(r'(/org/freedesktop/ModemManager1/Modem/\d+)', line)
                if match:
                    return match.group(1)
    return None

def get_own_number(modem_index):
    """Gets the modem's own phone number."""
    output = run_command(['mmcli', '-m', modem_index])
    if output:
        for line in output.splitlines():
            if 'own:' in line:
                number = line.split('own:')[1].strip()
                return number
    return "unknown"

# --- JSON Logging and Display Functions (Unchanged) ---
def log_to_json(data):
    """Appends an SMS record to the JSON file."""
    records = []
    if os.path.exists(JSON_FILE):
        try:
            with open(JSON_FILE, 'r', encoding='utf-8') as f:
                records = json.load(f)
        except json.JSONDecodeError:
            print(f"Warning: {JSON_FILE} is malformed. A new file will be created.")
            records = []
    
    records.append(data)

    try:
        with open(JSON_FILE, 'w', encoding='utf-8') as f:
            json.dump(records, f, indent=4, ensure_ascii=False)
    except IOError as e:
        print(f"Error: Could not write to {JSON_FILE}. Error: {e}")

def display_last_sms(count=10):
    """Displays the last N SMS records from the JSON log file."""
    print(f"--- Last {count} SMS Records (from {JSON_FILE}) ---")
    if not os.path.exists(JSON_FILE):
        print("Log file does not exist.")
        return
    try:
        with open(JSON_FILE, 'r', encoding='utf-8') as f:
            records = json.load(f)
        
        last_records = records[-count:]
        if not last_records:
            print("No SMS records found in log file.")

        for record in last_records:
            time_str = record.get('sent_time', 'N/A')
            if time_str == "N/A" or time_str == "unknown":
                time_str = record.get('received_time', 'N/A')
            print(f"Type: {record.get('type')}, Sender: {record.get('sender_number')}, Receiver: {record.get('receiver_number')}")
            print(f"Content: {record.get('message_content')}")
            print(f"Time: {time_str}\n-------------------")
    except (json.JSONDecodeError, IOError) as e:
        print(f"Failed to read or parse {JSON_FILE}. Error: {e}")

# --- Core SMS Sending and Receiving Functions (Unchanged) ---
def send_sms(modem_path, own_number, receiver_number, message_content):
    """Creates and sends an SMS message."""
    if len(receiver_number) == 11 and not receiver_number.startswith('+86'):
        receiver_number = f"+86{receiver_number}"
        print(f"Detected 11-digit number, automatically added country code: {receiver_number}")

    print(f"Sending SMS to {receiver_number}...")
    create_command = ['mmcli', '-m', modem_path, f"--messaging-create-sms=number='{receiver_number}',text='{message_content}'"]
    output = run_command(create_command)
    
    if not output or 'created sms' not in output:
        print("Failed to create SMS.")
        return

    sms_path = output.split(':')[-1].strip()
    send_output = run_command(['mmcli', '-s', sms_path, '--send'])
    if send_output is None:
        print("Failed to send SMS.")
        return

    print("SMS sent. Logging to JSON file...")
    log_entry = { "type": "sent", "sender_number": own_number, "receiver_number": receiver_number, "message_content": message_content, "sent_time": datetime.now().isoformat(), "received_time": "N/A"}
    log_to_json(log_entry)
    print("SMS record saved.")

def receive_sms(modem_path, own_number):
    """Checks for, processes, and logs all received SMS messages."""
    print("Checking for new received SMS...")
    list_output = run_command(['mmcli', '-m', modem_path, '--messaging-list-sms'])
    if not list_output:
        return
    
    sms_paths = re.findall(r'(/org/freedesktop/ModemManager1/SMS/\d+)', list_output)
    for sms_path in sms_paths:
        sms_info_output = run_command(['mmcli', '-s', sms_path])
        if not sms_info_output: continue

        details = {key.strip(): value.strip() for line in sms_info_output.splitlines() if ':' in line for key, value in [line.split(':', 1)]}
        
        if details.get('state') == 'received':
            print(f"New SMS found: {sms_path}")
            log_entry = {"type": "received", "sender_number": details.get('number', 'unknown'), "receiver_number": own_number, "message_content": details.get('text', ''), "sent_time": "unknown", "received_time": details.get('timestamp', 'N/A')}
            log_to_json(log_entry)
            run_command(['mmcli', '-s', sms_path, '--read'])
    print(f"All new SMS processed and saved to {JSON_FILE}")

# --- NEW: Functions for Listing and Deleting SMS ---

def list_modem_sms(modem_path, quiet=False):
    """Lists all SMS messages currently on the modem, returning their paths."""
    if not quiet:
        print("Listing SMS messages on the modem...")
    
    list_output = run_command(['mmcli', '-m', modem_path, '--messaging-list-sms'])
    if not list_output:
        if not quiet:
            print("Could not get SMS list from modem.")
        return []
    
    sms_paths = re.findall(r'(/org/freedesktop/ModemManager1/SMS/\d+)', list_output)
    if not sms_paths:
        if not quiet:
            print("No SMS messages found on the modem.")
        return []

    if not quiet:
        for i, path in enumerate(sms_paths):
            sms_info = run_command(['mmcli', '-s', path])
            details = {key.strip(): value.strip() for line in sms_info.splitlines() if ':' in line for key, value in [line.split(':', 1)]}
            sender = details.get('number', 'Unknown')
            content = details.get('text', '[No Content]').replace('\n', ' ')
            state = details.get('state', 'unknown')
            print(f"[{i}] From: {sender} | State: {state} | Content: \"{content[:50]}...\"")
    
    return sms_paths

def parse_delete_indices(index_str, max_index):
    """Parses a string of indices (e.g., "0,2,4-6") into a set of integers."""
    indices = set()
    parts = index_str.split(',')
    for part in parts:
        part = part.strip()
        if not part: continue
        if '-' in part:
            try:
                start, end = map(int, part.split('-'))
                if start > end:
                    start, end = end, start
                for i in range(start, end + 1):
                    if 0 <= i <= max_index:
                        indices.add(i)
            except ValueError:
                print(f"Warning: Invalid range '{part}' ignored.")
        else:
            try:
                index = int(part)
                if 0 <= index <= max_index:
                    indices.add(index)
                else:
                    print(f"Warning: Index {index} is out of bounds (0-{max_index}) and was ignored.")
            except ValueError:
                print(f"Warning: Invalid index '{part}' ignored.")
    return indices

def handle_delete(modem_path, index_str):
    """Handles the logic of deleting specified SMS messages."""
    all_sms_paths = list_modem_sms(modem_path, quiet=True)
    if not all_sms_paths:
        print("No SMS messages on the modem to delete.")
        return

    indices_to_delete = parse_delete_indices(index_str, len(all_sms_paths) - 1)
    if not indices_to_delete:
        print("No valid indices specified for deletion.")
        return

    print(f"Preparing to delete {len(indices_to_delete)} message(s)...")
    deleted_count = 0
    # Sort indices to delete in reverse order to avoid index shifting issues if mmcli re-orders
    for index in sorted(list(indices_to_delete), reverse=True):
        sms_path = all_sms_paths[index]
        print(f"Deleting SMS at index {index} (Path: {sms_path})...")
        delete_command = ['mmcli', '-m', modem_path, f'--messaging-delete-sms={sms_path}']
        if run_command(delete_command) is not None:
            print(f"Successfully deleted message at index {index}.")
            deleted_count += 1
        else:
            print(f"Failed to delete message at index {index}.")
    print(f"\nDeletion complete. {deleted_count} message(s) removed from the modem.")

def main():
    """Main entry point for the script."""
    # Print help message if no arguments are given or help is requested
    if len(sys.argv) == 1 or sys.argv[1] in ['-h', '--help']:
        print("SMS Manager Usage:")
        print("  python3 sms_manager_en.py <phone_number> \"<message>\"   # Send an SMS")
        print("  python3 sms_manager_en.py                             # Check for new SMS and show log")
        print("  python3 sms_manager_en.py --list                        # List all SMS on the modem with indices")
        print("  python3 sms_manager_en.py --delete <indices>            # Delete SMS from modem")
        print("    Examples:")
        print("      --delete 0        (deletes message at index 0)")
        print("      --delete 1,3,5    (deletes messages at indices 1, 3, and 5)")
        print("      --delete 2-4      (deletes messages at indices 2, 3, and 4)")
        print("      --delete 0,2-4    (deletes messages at indices 0, 2, 3, and 4)")
        sys.exit(0)

    modem_path = get_modem_path()
    if not modem_path:
        print("Error: Modem not found. Please ensure ModemManager service is running and a device is connected.")
        sys.exit(1)
        
    own_number = get_own_number(os.path.basename(modem_path))

    command = sys.argv[1]

    if command == '--list':
        list_modem_sms(modem_path)
    elif command == '--delete':
        if len(sys.argv) > 2:
            handle_delete(modem_path, sys.argv[2])
        else:
            print("Error: --delete requires indices. Use --list to see available messages.")
    elif len(sys.argv) == 3: # This is the "send" command
        send_sms(modem_path, own_number, sys.argv[1], sys.argv[2])
    else:
        print(f"Error: Unrecognized command or incorrect number of arguments. Use --help for usage info.")

if __name__ == "__main__":
    main()