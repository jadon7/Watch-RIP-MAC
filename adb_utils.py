import subprocess
import time
import re
import threading
from utils import logger  # Assuming logger is configured elsewhere

def get_adb_devices():
    """Returns a list of connected adb devices and their states."""
    devices = []
    try:
        result = subprocess.run(['adb', 'devices'], capture_output=True, text=True, check=True)
        lines = result.stdout.strip().split('\n')
        if len(lines) > 1:
            for line in lines[1:]:
                if line.strip() == "":
                    continue
                parts = re.split(r'\s+', line.strip())
                if len(parts) == 2:
                    device_id, state = parts
                    devices.append({'id': device_id, 'state': state})
    except FileNotFoundError:
        logger.error("'adb' command not found. Please ensure ADB is installed and in your PATH.")
        return [] # Return empty list if adb is not found
    except subprocess.CalledProcessError as e:
        logger.error(f"Error running 'adb devices': {e}")
        return [] # Return empty list on error
    except Exception as e:
        logger.error(f"An unexpected error occurred in get_adb_devices: {e}")
        return []
    return devices

def adb_monitor_thread(device_status: dict, status_changed_flags: dict, logger):
    """Monitors adb devices and updates their status."""
    last_known_status = {}
    while True:
        try:
            # Use get_adb_devices to fetch current state
            current_devices_info = get_adb_devices() 
            current_devices = {dev['id'] for dev in current_devices_info}
            
            device_map = {dev['id']: dev['state'] for dev in current_devices_info}

            # Check for new or changed devices
            for device_id in current_devices:
                state = device_map[device_id]
                last_known_state = last_known_status.get(device_id, None)

                if state == 'device':
                    # Only attempt root and update if state changes to 'device'
                    if last_known_state != 'device':
                        logger.info(f"Device {device_id} connected and authorized.")
                        # Try to restart adb as root
                        try:
                            logger.info(f"Attempting to restart adb as root for {device_id}...")
                            root_result = subprocess.run(
                                ['adb', '-s', device_id, 'root'],
                                capture_output=True, text=True, check=False, timeout=10
                            )
                            root_output = (root_result.stdout + root_result.stderr).lower()

                            if "restarting adbd as root" in root_output:
                                logger.info(f"Successfully executed 'adb root' for {device_id}. Device might disconnect and reconnect shortly.")
                                time.sleep(3) # Give time for potential reconnection
                            elif "adbd is already running as root" in root_output:
                                logger.info(f"'adb root' already enabled for {device_id}.")
                            else:
                                logger.warning(f"Could not restart adb as root for {device_id} (maybe not a debug build?). Output: {root_output.strip()}")

                        except subprocess.TimeoutExpired:
                            logger.warning(f"'adb root' command timed out for {device_id}.")
                        except Exception as e:
                            logger.error(f"Error executing 'adb root' for {device_id}: {e}")

                        # Update status regardless of root success/failure if state is 'device'
                        if device_id not in device_status or device_status.get(device_id, {}).get('state') != 'device':
                             device_status[device_id] = {'state': 'device', 'authorized': True}
                             status_changed_flags['main'] = True
                             logger.debug(f"Status updated for {device_id}: device")
                    
                    # Update last known state if confirmed 'device'
                    last_known_status[device_id] = 'device'

                elif state == 'unauthorized':
                    if last_known_state != 'unauthorized':
                        logger.warning(f"Device {device_id} is unauthorized. Please check the device screen.")
                        device_status[device_id] = {'state': 'unauthorized', 'authorized': False}
                        status_changed_flags['main'] = True
                        logger.debug(f"Status updated for {device_id}: unauthorized")
                    last_known_status[device_id] = 'unauthorized'

                elif state == 'offline':
                     if last_known_state != 'offline':
                        logger.warning(f"Device {device_id} is offline.")
                        device_status[device_id] = {'state': 'offline', 'authorized': False}
                        status_changed_flags['main'] = True
                        logger.debug(f"Status updated for {device_id}: offline")
                     last_known_status[device_id] = 'offline'

                else: # Handle other states
                    if last_known_state != state:
                        logger.info(f"Device {device_id} is in state: {state}")
                        device_status[device_id] = {'state': state, 'authorized': False}
                        status_changed_flags['main'] = True
                        logger.debug(f"Status updated for {device_id}: {state}")
                    last_known_status[device_id] = state

            # Detect disconnected devices
            disconnected_devices = set(last_known_status.keys()) - current_devices
            for device_id in disconnected_devices:
                logger.info(f"Device {device_id} disconnected.")
                if device_id in device_status:
                    del device_status[device_id]
                if device_id in last_known_status:
                     del last_known_status[device_id]
                status_changed_flags['main'] = True
                logger.debug(f"Status updated for {device_id}: disconnected")


        except Exception as e:
            # Log general errors in the monitoring loop without crashing it
            logger.error(f"An unexpected error occurred in adb_monitor_thread loop: {e}")

        # Wait before next check
        time.sleep(2) # Check every 2 seconds

# Example usage (if running this file directly for testing)
if __name__ == "__main__":
    import logging
    logging.basicConfig(level=logging.DEBUG, format='%(asctime)s - %(levelname)s - %(threadName)s - %(message)s')

    current_device_status = {}
    status_flags = {'main': False} # Use a dictionary to pass mutable flag

    # Setup logger for the example
    main_logger = logging.getLogger("ADBMONITOR")

    # Create and start the monitoring thread
    monitor = threading.Thread(target=adb_monitor_thread, args=(current_device_status, status_flags, main_logger), name="ADBMonitorThread", daemon=True)
    monitor.start()

    # Keep the main thread alive to observe changes
    try:
        while True:
            if status_flags['main']:
                 main_logger.info(f"--- Main Thread: Current Device Status: {current_device_status} ---")
                 status_flags['main'] = False # Reset flag
            time.sleep(1)
    except KeyboardInterrupt:
        main_logger.info("Stopping monitor.")

# Ensure threading is imported if running standalone test
import threading 