#!/bin/bash -e

# Variables
root="$1"

# Use root directory
cd "$root"

# Repackage wheels
"$root/venv/bin/python" << "EOF"
import glob
import os
import packaging.tags
import packaging.utils
import packaging.version
import pathlib
import shutil
import tempfile
import wheel.wheelfile

# Function to replace the value of a specified key in a file
def replace_value(path, key, value):
  # Flag to indicate if the key's value has been replaced
  is_value_replaced = False

  # List to store the lines of the file
  lines = []

  # Open the file for reading
  with open(path, "r") as file:
    # Iterate over each line in the file
    for line in file:
      # Remove any trailing whitespace characters from the line
      line = line.rstrip()

      # If the key's value has not been replaced yet
      if not is_value_replaced:
        # Check if the line starts with the specified key followed by a colon
        if line.startswith(f"{key}: "):
          # Replace the line with the new key-value pair
          line = f"{key}: {value}"

          # Set the flag to indicate that the value has been replaced
          is_value_replaced = True

        # If the line is empty
        if line == "":
          # Set the flag to indicate that no replacement is needed beyond this point
          is_value_replaced = True

      # Add the (possibly modified) line to the list of lines
      lines.append(line)

  # Open the file for writing (this will overwrite the original file)
  with open(path, "w") as file:
    # Write the modified lines back to the file
    file.write("\n".join(lines))

# Path to the wheels
wheelhouse = os.getenv("WHEEL_HOUSE", "wheelhouse/*.whl")

# Retrieve environment variables for the new wheel attributes
new_name = os.getenv("WHEEL_NAME", "")
new_version = os.getenv("WHEEL_VERSION", "")
new_build_number = os.getenv("WHEEL_BUILD_NUMBER", "")
new_tags = os.getenv("WHEEL_TAGS", "")

# Parse the new name if provided
if new_name != "":
  new_name = new_name.replace("-", "_")
else:
  new_name = None

# Parse the new version if provided
if new_version != "":
  new_version = packaging.version.parse(new_version)
else:
  new_version = None

# Parse the new build number if provided
if new_build_number != "":
  new_build_number = new_build_number # TODO
else:
  new_build_number = None

# Parse the new tags if provided
if new_tags != "":
  new_tags = packaging.tags.parse_tag(new_tags)
else:
  new_tags = None

# Iterate over each .whl file in the "wheelhouse" directory
for wheel_path in glob.glob(wheelhouse):
  # Parse the wheel filename into components
  name, version, build_number, tags = packaging.utils.parse_wheel_filename(os.path.basename(wheel_path))

  # Normalized package name (without hyphens)
  normalized_name = name.replace("-", "_")

  # Create a temporary directory to work with the wheel contents
  with tempfile.TemporaryDirectory() as directory:
    # Extract the contents of the wheel file into the temporary directory
    with wheel.wheelfile.WheelFile(wheel_path, "r") as wf:
      for zinfo in wf.filelist:
        wf.extract(zinfo, directory)

        # Set permissions to the same values as they were set in the archive
        # We have to do this manually due to
        # https://github.com/python/cpython/issues/59999
        permissions = zinfo.external_attr >> 16 & 0o777
        pathlib.Path(directory).joinpath(zinfo.filename).chmod(permissions)

    # Remove the original wheel file as it's no longer needed
    os.remove(wheel_path)

    # Define the path to the .dist-info directory
    dist_info = os.path.join(directory, f"{normalized_name}-{version}.dist-info")

    # Replace the name in the METADATA file if a new name is provided
    if new_name:
      replace_value(os.path.join(dist_info, "METADATA"), "Name", new_name.replace("_", "-"))

    # Replace the version in the METADATA file if a new version is provided
    if new_version:
      replace_value(os.path.join(dist_info, "METADATA"), "Version", new_version)

    # Generate a string representation of the tags
    tags_str = ".".join(str(tag) if i == 0 else tag.platform for i, tag in enumerate(new_tags or tags))

    # Replace the tags in the WHEEL file if new tags are provided
    if new_tags:
      replace_value(os.path.join(dist_info, "WHEEL"), "Tag", tags_str)

      # TODO:
      #  for tag in tags:
      #   append(".dist-info" / "WHEEL", "Tag", tag)

    # If the name or version was changed, rename the .dist-info directory accordingly
    if new_name or new_version:
      shutil.move(dist_info, os.path.join(directory, f"{new_name or normalized_name}-{new_version or version}.dist-info"))

    # Construct a list of the new or existing wheel components
    new_wheel_name = [
      new_name or normalized_name,
      new_version or version,
      new_build_number or build_number,
      tags_str,
    ]

    # Join the parts to form the new wheel filename
    new_wheel_name = "-".join(str(part) for part in new_wheel_name if part) + ".whl"

    # Define the full path for the new wheel file
    new_wheel_path = os.path.join(os.path.dirname(wheel_path), new_wheel_name)

    # Write the modified files back into a new wheel file
    with wheel.wheelfile.WheelFile(new_wheel_path, "w") as wf:
      wf.write_files(directory)
EOF
