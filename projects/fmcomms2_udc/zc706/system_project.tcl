
source ../../scripts/adi_env.tcl
source $ad_hdl_dir/projects/scripts/adi_project.tcl

set project_name udconv_zc706

adi_project_create $project_name

adi_project_files $project_name [list "$ad_hdl_dir/library/common/ad_iobuf.v" \
                                      "system_top.v" \
                                      "system_constr.xdc" \
                                      "$ad_hdl_dir/projects/common/zc706/zc706_system_constr.xdc" \
                                      "$ad_hdl_dir/projects/fmcomms2/zc706/system_constr.xdc"]

adi_project_run $project_name

