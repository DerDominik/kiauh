### base variables
SYSTEMDDIR="/etc/systemd/system"
KLIPPY_ENV="${HOME}/klippy-env"
KLIPPER_DIR="${HOME}/klipper"

klipper_setup_dialog(){
  status_msg "Initializing Klipper installation ..."

  ### check for existing klipper service installations
  if [ "$(systemctl list-units --full -all -t service --no-legend | grep -F "klipper.service")" ] || [ "$(systemctl list-units --full -all -t service --no-legend | grep -E "klipper-[[:digit:]].service")" ]; then
    ERROR_MSG="At least one Klipper service is already installed!\n Please remove Klipper first, before installing it again." && return 0
  fi

  ### initial printer.cfg path check
  check_klipper_cfg_path

  ### ask for amount of instances to create
  while true; do
      echo
      read -p "${cyan}###### How many Klipper instances do you want to set up?:${default} " INSTANCE_COUNT
      echo
      if [ $INSTANCE_COUNT == 1 ]; then
        read -p "${cyan}###### Create $INSTANCE_COUNT single instance? (Y/n):${default} " yn
      else
        read -p "${cyan}###### Create $INSTANCE_COUNT instances? (Y/n):${default} " yn
      fi
      case "$yn" in
        Y|y|Yes|yes|"")
          echo -e "###### > Yes"
          status_msg "Creating $INSTANCE_COUNT Klipper instances ..."
          klipper_setup
          break;;
        N|n|No|no)
          echo -e "###### > No"
          warn_msg "Exiting Klipper setup ..."
          echo
          break;;
        *)
          print_unkown_cmd
          print_msg && clear_msg;;
    esac
  done
}

install_klipper_packages(){
  ### Packages for python cffi
  PKGLIST="python-virtualenv virtualenv python-dev libffi-dev build-essential"
  ### kconfig requirements
  PKGLIST="${PKGLIST} libncurses-dev"
  ### hub-ctrl
  PKGLIST="${PKGLIST} libusb-dev"
  ### AVR chip installation and building
  PKGLIST="${PKGLIST} avrdude gcc-avr binutils-avr avr-libc"
  ### ARM chip installation and building
  PKGLIST="${PKGLIST} stm32flash libnewlib-arm-none-eabi"
  PKGLIST="${PKGLIST} gcc-arm-none-eabi binutils-arm-none-eabi libusb-1.0"
  ### dbus requirement for DietPi
  PKGLIST="${PKGLIST} dbus"

  ### Update system package info
  status_msg "Running apt-get update..."
  sudo apt-get update

  ### Install desired packages
  status_msg "Installing packages..."
  sudo apt-get install --yes ${PKGLIST}
}

create_klipper_virtualenv(){
  status_msg "Installing python virtual environment..."
  # Create virtualenv if it doesn't already exist
  [ ! -d ${KLIPPY_ENV} ] && virtualenv -p python2 ${KLIPPY_ENV}
  # Install/update dependencies
  ${KLIPPY_ENV}/bin/pip install -r ${KLIPPER_DIR}/scripts/klippy-requirements.txt
}

create_single_klipper_startscript(){
### create systemd service file
sudo /bin/sh -c "cat > $SYSTEMDDIR/klipper.service" << SINGLE_STARTSCRIPT
#Systemd service file for klipper
[Unit]
Description=Starts klipper on startup
After=network.target
[Install]
WantedBy=multi-user.target
[Service]
Type=simple
User=$USER
RemainAfterExit=yes
ExecStart=${KLIPPY_ENV}/bin/python ${KLIPPER_DIR}/klippy/klippy.py ${PRINTER_CFG} -l ${KLIPPER_LOG} -a ${KLIPPY_UDS}
Restart=always
RestartSec=10
SINGLE_STARTSCRIPT
}

create_multi_klipper_startscript(){
### create multi instance systemd service file
sudo /bin/sh -c "cat > $SYSTEMDDIR/klipper-$INSTANCE.service" << MULTI_STARTSCRIPT
#Systemd service file for klipper
[Unit]
Description=Starts klipper instance $INSTANCE on startup
After=network.target
[Install]
WantedBy=multi-user.target
[Service]
Type=simple
User=$USER
RemainAfterExit=yes
ExecStart=${KLIPPY_ENV}/bin/python ${KLIPPER_DIR}/klippy/klippy.py ${PRINTER_CFG} -I ${TMP_PRINTER} -l ${KLIPPER_LOG} -a ${KLIPPY_UDS}
Restart=always
RestartSec=10
MULTI_STARTSCRIPT
}

create_minimal_printer_cfg(){
/bin/sh -c "cat > $1" << MINIMAL_CFG
[mcu]
serial: /dev/serial/by-id/<your-mcu-id>

[pause_resume]

[display_status]

[virtual_sdcard]
path: ~/gcode_files

[printer]
kinematics: none
max_velocity: 1000
max_accel: 1000
MINIMAL_CFG
}

klipper_setup(){
  ### get printer config directory
  source_kiauh_ini
  PRINTER_CFG_LOC="$klipper_cfg_loc"

  ### clone klipper
  cd ${HOME}
  status_msg "Downloading Klipper ..."
  [ -d $KLIPPER_DIR ] && rm -rf $KLIPPER_DIR
  git clone $KLIPPER_REPO
  status_msg "Download complete!"

  ### install klipper dependencies and create python virtualenv
  status_msg "Installing dependencies ..."
  install_klipper_packages
  create_klipper_virtualenv

  ### create shared gcode_files folder
  [ ! -d ${HOME}/gcode_files ] && mkdir -p ${HOME}/gcode_files
  ### create shared config folder
  [ ! -d $PRINTER_CFG_LOC ] && mkdir -p $PRINTER_CFG_LOC

  ### create klipper instances
  INSTANCE=1
  if [ $INSTANCE_COUNT -eq $INSTANCE ]; then
    create_single_klipper_instance
  else
    create_multi_klipper_instance
  fi
}

create_single_klipper_instance(){
  status_msg "Setting up 1 Klipper instance ..."

  ### single instance variables
  KLIPPER_LOG=/tmp/klippy.log
  KLIPPY_UDS=/tmp/klippy_uds
  PRINTER_CFG="$PRINTER_CFG_LOC/printer.cfg"

  ### create instance
  status_msg "Creating single Klipper instance ..."
  status_msg "Installing system start script ..."
  create_single_klipper_startscript

  ### create printer config directory if missing
  [ ! -d $PRINTER_CFG_LOC ] && mkdir -p $PRINTER_CFG_LOC

  ### create basic configs if missing
  [ ! -f $PRINTER_CFG ] && create_minimal_printer_cfg "$PRINTER_CFG"

  ### enable instance
  sudo systemctl enable klipper.service
  ok_msg "Single Klipper instance created!"

  ### launching instance
  status_msg "Launching Klipper instance ..."
  sudo systemctl start klipper

  ### confirm message
  CONFIRM_MSG="Single Klipper instance has been set up!"
  print_msg && clear_msg
}

create_multi_klipper_instance(){
  status_msg "Setting up $INSTANCE_COUNT instances of Klipper ..."
  while [ $INSTANCE -le $INSTANCE_COUNT ]; do
    ### multi instance variables
    KLIPPER_LOG=/tmp/klippy-$INSTANCE.log
    KLIPPY_UDS=/tmp/klippy_uds-$INSTANCE
    TMP_PRINTER=/tmp/printer-$INSTANCE
    PRINTER_CFG="$PRINTER_CFG_LOC/printer_$INSTANCE/printer.cfg"

    ### create instance
    status_msg "Creating instance #$INSTANCE ..."
    create_multi_klipper_startscript

    ### create printer config directory if missing
    [ ! -d $PRINTER_CFG_LOC/printer_$INSTANCE ] && mkdir -p $PRINTER_CFG_LOC/printer_$INSTANCE

    ### create basic configs if missing
    [ ! -f $PRINTER_CFG ] && create_minimal_printer_cfg "$PRINTER_CFG"

    ### enable instance
    sudo systemctl enable klipper-$INSTANCE.service
    ok_msg "Klipper instance $INSTANCE created!"

    ### launching instance
    status_msg "Launching Klipper instance $INSTANCE ..."
    sudo systemctl start klipper-$INSTANCE

    ### instance counter +1
    INSTANCE=$(expr $INSTANCE + 1)
  done

  ### confirm message
  CONFIRM_MSG="$INSTANCE_COUNT Klipper instances have been set up!"
  print_msg && clear_msg
}


##############################################################################################
#********************************************************************************************#
##############################################################################################


flash_routine(){
  echo
  top_border
  echo -e "|        ${red}~~~~~~~~~~~ [ ATTENTION! ] ~~~~~~~~~~~~${default}        |"
  hr
  echo -e "| Flashing a Smoothie based board with this method will |"
  echo -e "| certainly fail. This applies to boards like the SKR   |"
  echo -e "| V1.3 / V1.4. You have to copy the firmware file to    |"
  echo -e "| the SD card manually and rename it to 'firmware.bin'. |"
  hr
  echo -e "| You can find the file in: ~/klipper/out/klipper.bin   |"
  bottom_border
  while true; do
    read -p "${cyan}###### Do you want to continue? (Y/n):${default} " yn
    case "$yn" in
      Y|y|Yes|yes|"")
        echo -e "###### > Yes"
        FLASH_FIRMWARE="true"
        get_mcu_id
        break;;
      N|n|No|no)
        echo -e "###### > No"
        FLASH_FIRMWARE="false"
        break;;
      *)
        print_unkown_cmd
        print_msg && clear_msg;;
    esac
  done
}

flash_routine_sd(){
  echo
  top_border
  echo -e "|        ${red}~~~~~~~~~~~ [ ATTENTION! ] ~~~~~~~~~~~~${default}        |"
  hr
  echo -e "| If you have a Smoothie based board with an already    |"
  echo -e "| flashed Klipper Firmware, you can now choose to flash |"
  echo -e "| directly from the internal SD if your control board   |"
  echo -e "| is supported by that function.                        |"
  bottom_border
  while true; do
    read -p "${cyan}###### Do you want to continue? (Y/n):${default} " yn
    case "$yn" in
      Y|y|Yes|yes|"")
        echo -e "###### > Yes"
        FLASH_FW_SD="true"
        get_mcu_id
        break;;
      N|n|No|no)
        echo -e "###### > No"
        FLASH_FW_SD="false"
        break;;
      *)
        print_unkown_cmd
        print_msg && clear_msg;;
    esac
  done
}

select_mcu_id(){
  if [ ${#mcu_list[@]} -ge 1 ]; then
    top_border
    echo -e "|               ${red}!!! IMPORTANT WARNING !!!${default}               |"
    hr
    echo -e "| Make sure, that you select the correct ID for the MCU |"
    echo -e "| you have build the firmware for in the previous step! |"
    blank_line
    echo -e "| This is especially important if you use different MCU |"
    echo -e "| models which each require their own firmware!         |"
    blank_line
    echo -e "| ${red}ONLY flash a firmware created for the respective MCU!${default} |"
    bottom_border

    ### list all mcus
    i=1
    for mcu in ${mcu_list[@]}; do
      echo -e "$i) ${cyan}$mcu${default}"
      i=$(expr $i + 1)
    done
    while true; do
      echo
      read -p "${cyan}###### Please select the ID for flashing:${default} " selected_index
      mcu_index=$(echo $((selected_index - 1)))
      selected_mcu_id="${mcu_list[$mcu_index]}"
      echo -e "\nYou have selected to flash:\n● MCU #$selected_index: $selected_mcu_id\n"
      while true; do
        read -p "${cyan}###### Do you want to continue? (Y/n):${default} " yn
        case "$yn" in
          Y|y|Yes|yes|"")
            echo -e "###### > Yes"
            status_msg "Flashing $selected_mcu_id ..."
            if [ "$FLASH_FIRMWARE" = "true" ]; then
              flash_mcu
            fi
            if [ "$FLASH_FW_SD" = "true" ]; then
              flash_mcu_sd
            fi
            if [ "$FLASH_FIRMWARE_MARLIN" = "true" ]; then
              flash_mcu_marlin
            fi
            break;;
          N|n|No|no)
            echo -e "###### > No"
            break;;
          *)
            print_unkown_cmd
            print_msg && clear_msg;;
        esac
      done
      break
    done
  fi
}

flash_routine_marlin(){
  echo
  top_border
  echo -e "|        ${red}~~~~~~~~~~~ [ ATTENTION! ] ~~~~~~~~~~~~${default}        |"
  hr
  echo -e "| Flashing original Marlin Firmware file                |"
  echo -e "| File must be located in: ~/marlin/firmware.hex        |"
  bottom_border
  while true; do
    read -p "${cyan}###### Do you want to continue? (Y/n):${default} " yn
    case "$yn" in
      Y|y|Yes|yes|"")
        echo -e "###### > Yes"
        FLASH_FIRMWARE_MARLIN="true"
        if [ -f "$MARLIN_FILE" ]; then
          get_mcu_id
        else 
            echo "$MARLIN_FILE does not exist."
        fi
        break;;
      N|n|No|no)
        echo -e "###### > No"
        FLASH_FIRMWARE_MARLIN="false"
        break;;
      *)
        print_unkown_cmd
        print_msg && clear_msg;;
    esac
  done
}

flash_mcu(){
  klipper_service "stop"
  if ! make flash FLASH_DEVICE="${mcu_list[$mcu_index]}" ; then
    warn_msg "Flashing failed!"
    warn_msg "Please read the console output above!"
  else
    ok_msg "Flashing successfull!"
  fi
  klipper_service "start"
}

flash_mcu_sd(){
  klipper_service "stop"

  ### write each supported board to the array to make it selectable
  board_list=()
  for board in $(~/klipper/scripts/flash-sdcard.sh -l | tail -n +2); do
    board_list+=($board)
  done

  i=0
  top_border
  echo -e "|  Please select the type of board that corresponds to  |"
  echo -e "|  the currently selected MCU ID you chose before.      |"
  blank_line
  echo -e "|  The following boards are currently supported:        |"
  hr
  ### display all supported boards to the user
  for board in ${board_list[@]}; do
    if [ $i -lt 10 ]; then
      printf "|  $i) %-50s|\n" "${board_list[$i]}"
    else
      printf "|  $i) %-49s|\n" "${board_list[$i]}"
    fi
    i=$((i + 1))
  done
  quit_footer

  ### make the user select one of the boards
  while true; do
    read -p "${cyan}###### Please select board type:${default} " choice
    if [ $choice = "q" ] || [ $choice = "Q" ]; then
      clear && advanced_menu && break
    elif [ $choice -le ${#board_list[@]} ]; then
      selected_board="${board_list[$choice]}"
      break
    else
      clear && print_header
      ERROR_MSG="Invalid choice!" && print_msg && clear_msg
      flash_mcu_sd
    fi
  done

  while true; do
    top_border
    echo -e "| If your board is flashed with firmware that connects  |"
    echo -e "| at a custom baud rate, please change it now.          |"
    blank_line
    echo -e "| If you are unsure, stick to the default 250000!       |"
    bottom_border
    echo -e "${cyan}###### Please set the baud rate:${default} "
    unset baud_rate
    while [[ ! $baud_rate =~ ^[0-9]+$ ]]; do
      read -e -i "250000" -e baud_rate
      selected_baud_rate=$baud_rate
      break
    done
  break
  done

  if ! ${HOME}/klipper/scripts/flash-sdcard.sh -b "$selected_baud_rate" "$selected_mcu_id" "$selected_board" ; then
    warn_msg "Flashing failed!"
    warn_msg "Please read the console output above!"
  else
    ok_msg "Flashing successfull!"
  fi

  klipper_service "start"
}

  flash_mcu_marlin(){
  klipper_service "stop"
  if ! avrdude -p M2560 -c wiring -P ${mcu_list[$mcu_index]} -U flash:w:$MARLIN_FILE:i -v ; then
    warn_msg "Flashing failed!"
    warn_msg "Please read the console output above!"
  else
    ok_msg "Flashing successfull!"
  fi
}

build_fw(){
  if [ -d $KLIPPER_DIR ]; then
    cd $KLIPPER_DIR
    status_msg "Initializing firmware build ..."
    make clean
    make menuconfig
    status_msg "Building firmware ..."
    make && ok_msg "Firmware built!"
  else
    warn_msg "Can not build firmware without a Klipper directory!"
  fi
}

### grab the mcu id
get_mcu_id(){
  echo
  top_border
  echo -e "| Please make sure your MCU is connected to the Pi!     |"
  echo -e "| If the MCU is not connected yet, connect it now.      |"
  bottom_border
  while true; do
    echo -e "${cyan}"
    read -p "###### Press any key to continue ... " yn
    echo -e "${default}"
    case "$yn" in
      *)
        break;;
    esac
  done
  status_msg "Identifying the ID of your MCU ..."
  sleep 2
  unset MCU_ID
  ### if there are devices found, continue, else show warn message
  if ls /dev/serial/by-id/* 2>/dev/null 1>&2; then
    mcu_count=1
    mcu_list=()
    status_msg "The ID of your printers MCU is:"
    ### loop over the IDs, write every ID as an item of the array 'mcu_list'
    for mcu in /dev/serial/by-id/*; do
      declare "mcu_id_$mcu_count"="$mcu"
      mcu_id="mcu_id_$mcu_count"
      mcu_list+=("${!mcu_id}")
      echo " ● MCU #$mcu_count: ${cyan}$mcu${default}"
      mcu_count=$(expr $mcu_count + 1)
    done
    unset mcu_count
  else
    warn_msg "Could not retrieve ID!"
    warn_msg "Printer not plugged in or not detectable!"
  fi
}