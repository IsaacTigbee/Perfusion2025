This is the code repository for the Perfusion Team of CONNExIN 2025(Bootcamp Choice Award Winners).
We are currently pursuing the goal of creating A Comprehensive Pipeline For Reproducible Analysis of ASL Using Quantiphyse.
We have picked Quantiphyse because it INTEGRATES well with FSL and it works as an all-in-one container for compact analysis saving us the stress of moving from tool to tool throughout the analysis process.
This repository houses mostly scripts - shell and Python(in the future) for running different steps in said comprehensive and reproducible ASL analysis pipeline. 
In line with Open Science, we are keeping every usable aspect of this pipeline available for all to use and as easy as possible to understand. 

Before I proceed, here are the names and affiliations of the individuals who contributed in putting this all together:

Isaac Manny Tigbee - Department of Medical Imaging, University for Development Studies, Tamale-Ghana

Alaa Bessadok - Department of Computer Science, University of Carthage, Tunis, Tunisia

Jeremiah Daniel - College of Health Sciences, Obafemi Awolowo University, Ile-Ife, Osun, Nigeria

Bilkisu Usman Farouk, MD - Department of Radiology, Barau Dikko Teaching Hospital, Kaduna, Nigeria.

Bankole Happiness - Department of Radiology, Lagos University Teaching Hospital, Lagos, Nigeria. 

Ernest Okyere Darko - Department of Medical Imaging, University for Development Studies, Tamale-Ghana

Awamba Abraham Izuchukwu - Institute of Radiography, Lagos, Nigeria

Said Ibrahim Said - Department of Radiology, Federal Teaching Hospital Gombe, Gombe, Nigeria

GUIDE TO CODE CONTENT:

-> datastructure.sh

-- To check for BIDS compliance 

-- Dependencies: dcm2niix v1.0.20250505 deno v2.3.3

To get the dependecies set up:

Navigate to your conda environment (For example: conda activate qp_env) 

Run conda install -c conda-forge dcm2niix

Run conda install conda-forge::deno

--Usage:

chmod +x datastructure.sh

./datastructure.sh <path to your BIDS dataset>


-> quick_qc.sh

-- To check for some IQMs and quality of input data

-- Dependencies: fslmaths fslstats fslsplit fslmerge fslval fslhd bet mcflirt flirt python3 bc awk sed grep

To get the dependencies set up:

Run  sudo apt update
     sudo apt install python3 python3-pip -y
     
Follow the [FSL Documentation] at http://fsl.fmrib.ox.ac.uk/fsl/fslwiki/FslInstallation to install FSL.

--Usage:

chmod +x quick_qc.sh

./quick_qc.sh <path to your BIDS dataset>


-> full_cbf_quant.sh

-- To run preprocessing and analysis using Quantiphyse and FSL

-- Dependencies: fslmaths, oxasl, python3

To get the dependencies set up:

Follow the [Quantiphyse Documentation] at https://quantiphyse.readthedocs.io/en/latest/basics/install.html to install Quantiphyse and the quantiphyse-asl plugin

fslmaths will be available from prior FSL installation

python3 will be available from prior installation.

--Usage:

chmod +x full_cbf_quant.sh

./full_cbf_quant.sh <path to your BIDS dataset>

EASY MISTAKES:
Using scripts outside specified conda environment. Always remember to activate conda environment as some installed dependencies may not be available in your base environment.
Running "./" without making the script executable first. Always chmod before executing script.

IMPORTANT THINGS TO NOTE:
The code content of this repo is constantly being updated for clarity, correctness, and robustness.
Every script contains information about usage and dependencies within it.
These scripts are NOT the only way or internationally accepted way of running the required steps for ASL analysis, they just provide a simple, compact, and reproducible approach.
Kindly use extensively to test the edges of the functionalities. This would help us fix bugs and deal with errors as we keep populating this repository.
If you have any suggestions or collaboration requests for us, reach out to the program team at 	info.camera.mri@gmail.com. We would love to hear from you.
