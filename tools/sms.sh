#!/bin/bash

# Get the modem path using awk to extract the first field
MODEM_PATH=$(mmcli -L | awk '/Modem/ {print $1}')

if [ -z "$MODEM_PATH" ]; then
    echo "Modem not found."
    exit 1
fi

# 从设备路径中提取调制解调器索引号
# 例如，从 /org/freedesktop/ModemManager1/Modem/0 中提取出 '0'
MODEM_INDEX=$(basename "$MODEM_PATH")


# Get the local phone number
#OWN_NUMBER=$(mmcli -m "$MODEM_INDEX" | grep 'Numbers:' | awk -F"'" '{print $2}' | tr -d ', ' | sed "s/'//g")
OWN_NUMBER=$(mmcli -m "$MODEM_INDEX" | grep Numbers | awk -F'own:' '{print $2}')
echo $OWN_NUMBER
#exit 1

# If the local number is empty, set a placeholder
if [ -z "$OWN_NUMBER" ]; then
    OWN_NUMBER="unknown"
    echo "Warning: Unable to get local number. Please check ModemManager configuration."
fi

# Define the path for the JSON file
JSON_FILE="sms.json"

# If the file does not exist, create an empty JSON array
if [ ! -f "$JSON_FILE" ]; then
    echo "[]" > "$JSON_FILE"
fi

# Function to display the last 10 SMS records from the JSON file
function display_last_sms() {
    echo "--- Last 10 SMS Records ---"
    jq -r '
        .[-10:] | .[] |
        "Type: \(.type)\nSender: \(.sender_number)\nReceiver: \(.receiver_number)\nContent: \(.message_content)\nTime: \(.sent_time | select(. != "N/A"))\(.received_time | select(. != "N/A"))\n-------------------"
    ' "$JSON_FILE"
}

# Check command-line arguments
if [ -n "$1" ] && [ -n "$2" ]; then
    RECEIVER_NUMBER="$1"
    MESSAGE_CONTENT="$2"

    # If the number is 11 digits and doesn't start with +86, automatically add it
    if [[ ! "$RECEIVER_NUMBER" =~ ^\+86 ]] && [ ${#RECEIVER_NUMBER} -eq 11 ]; then
        RECEIVER_NUMBER="+86$RECEIVER_NUMBER"
        echo "Detected 11-digit number, automatically added country code: $RECEIVER_NUMBER"
    fi

    echo "Sending SMS to $RECEIVER_NUMBER..."

    # Use sed to reliably extract the full path
    SMS_PATH=$(mmcli -m "$MODEM_PATH" --messaging-create-sms="number='$RECEIVER_NUMBER',text='$MESSAGE_CONTENT'" | grep 'created sms:' | awk -F'created sms:' '{print $2}' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

    if [ -z "$SMS_PATH" ]; then
        echo "Failed to create SMS."
        exit 1
    fi

    # Send the SMS
    mmcli -s "$SMS_PATH" --send

    echo "SMS sent. Logging to JSON file..."

    # Construct the JSON object
    SENT_TIME=$(date -Is)

    json_entry=$(jq -n \
        --arg sender_number "$OWN_NUMBER" \
        --arg receiver_number "$RECEIVER_NUMBER" \
        --arg message_content "$MESSAGE_CONTENT" \
        --arg sent_time "$SENT_TIME" \
        '{
            "type": "sent",
            "sender_number": $sender_number,
            "receiver_number": $receiver_number,
            "message_content": $message_content,
            "sent_time": $sent_time,
            "received_time": "N/A"
        }')

    # Append the new JSON object to the file
    jq --argjson new_entry "$json_entry" '. + [$new_entry]' "$JSON_FILE" > temp.json && mv temp.json "$JSON_FILE"

    echo "SMS record saved."

else
    # No send arguments provided, execute the receive SMS logic
    echo "Checking for new received SMS..."
    
    # Get and process all received SMS
    mmcli -m "$MODEM_PATH" --messaging-list-sms | awk '{print $1}' | while read -r sms_path; do
        if [ -n "$sms_path" ]; then
            sms_info=$(mmcli -s "$sms_path")
            
            # --- New, corrected extraction logic ---
            # Extract sender number
            sender_number=$(echo "$sms_info" | awk '/number:/ {print $NF}')
            
            # Extract message content, handling potential multi-line content
            # The sed command removes "text:" and any leading whitespace
            #message_content=$(echo "$sms_info" | sed -n '/text:/,/\s*--/p' | sed '$d' | sed 's/^\s*text: //')
            message_content=$(echo "$sms_info" | grep 'text:' |  awk -F'text:' '{print $2}')

            #OWN_NUMBER=$(mmcli -m "$MODEM_INDEX" | grep Numbers | awk -F'own:' '{print $2}')


            # Extract received timestamp
            received_time=$(echo "$sms_info" | grep 'timestamp:' | awk -F'timestamp:' '{print $2}')
            
            state=$(echo "$sms_info" | grep 'state:' | awk -F'state:' '{print $2}')

            if [ "$state" = "received" ]; then
                echo "New SMS found: $sms_path"

                json_entry=$(jq -n \
                    --arg sender_number "$sender_number" \
                    --arg receiver_number "$OWN_NUMBER" \
                    --arg message_content "$message_content" \
                    --arg received_time "$received_time" \
                    '{
                        "type": "received",
                        "sender_number": $sender_number,
                        "receiver_number": $receiver_number,
                        "message_content": $message_content,
                        "sent_time": "unknown",
                        "received_time": $received_time
                    }')
                
                jq --argjson new_entry "$json_entry" '. + [$new_entry]' "$JSON_FILE" > temp.json && mv temp.json "$JSON_FILE"

                mmcli -s "$sms_path" --read
            fi
        fi
    done

    echo "All new SMS processed and saved to $JSON_FILE"
    display_last_sms
fi
