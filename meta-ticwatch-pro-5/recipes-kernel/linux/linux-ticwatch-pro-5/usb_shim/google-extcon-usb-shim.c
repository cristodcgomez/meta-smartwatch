/* SPDX-License-Identifier: GPL-2.0 */
/* Copyright 2023 Google LLC */

#include <linux/extcon.h>
#include <linux/extcon-provider.h>
#include <linux/module.h>
#include <linux/moduleparam.h>
#include <linux/mutex.h>
#include <linux/of.h>
#include <linux/platform_device.h>
#include <linux/types.h>

static bool usb_force_disable_boot = false;
module_param(usb_force_disable_boot, bool, 0);
MODULE_PARM_DESC(usb_force_disable_boot,
		"Boot setting for whether extcon events are forwarded to " \
		"the destination. This can then be changed at runtime.\n" \
		"0/1 correspond to extcon forwarding / extcon blocking .\n" \
		"Note: Effect of this parameter is guarded by the dt " \
		"property 'usb-gate-supported'.\n");

static const unsigned int supported_cables[] = {
	EXTCON_USB,
	EXTCON_NONE /* sentinel */
};

struct extcon_usb_shim {
	struct mutex lock;
	struct device *dev;
	struct extcon_dev *extcon;

	/* The "supplier" is the extcon device we receive state updates from.
	 * i.e. the "real" extcon device.
	 */
	struct notifier_block supplier_notifier;
	bool usb_gate_support;

	bool supplier_connected;

	/* Whether the USB PHY will be force disabled */
	bool usb_force_disable;

	bool force_report_connected;
};

static void update(struct extcon_usb_shim *shim, bool *state, bool newval)
{
	union extcon_property_value prop;
	bool usb_on;

	mutex_lock(&shim->lock);
	if (state)
		*state = newval;

	usb_on = shim->supplier_connected && !shim->usb_force_disable;
	usb_on |= !!shim->force_report_connected;

	if (usb_on) {
		prop.intval = false;
		extcon_set_property(shim->extcon, EXTCON_USB,
				EXTCON_PROP_USB_SS, prop);
	}

	extcon_set_state_sync(shim->extcon, EXTCON_USB, usb_on);

	mutex_unlock(&shim->lock);
}

static int supplier_change(struct notifier_block *notifier,
			unsigned long supplier_connected, void *unused)
{
	struct extcon_usb_shim *shim = container_of(notifier,
						struct extcon_usb_shim,
						supplier_notifier);

	update(shim, &shim->supplier_connected, supplier_connected);

	return NOTIFY_DONE;
}

static ssize_t force_disable_store(struct device *dev,
				struct device_attribute *attr,
				const char *buf, size_t count)
{
	struct platform_device *pdev = container_of(dev,
						struct platform_device, dev);
	struct extcon_usb_shim *shim = platform_get_drvdata(pdev);
	bool force_disable;
	int ret;

	ret = kstrtobool(buf, &force_disable);
	if (ret < 0) {
		return ret;
	}

	if (!shim->usb_gate_support) {
		/* Return success even if we do not support gating to prevent
		 * adding conditions to common userspace code that attempts
		 * to write to this path.
		 */
		return count;
	}

	update(shim, &shim->usb_force_disable, force_disable);

	return count;
}

static ssize_t force_disable_show(struct device *dev,
				struct device_attribute *attr, char *buf)
{
	struct platform_device *pdev = container_of(dev,
						struct platform_device, dev);
	struct extcon_usb_shim *shim = platform_get_drvdata(pdev);

	return scnprintf(buf, PAGE_SIZE, "%u\n", shim->usb_force_disable);
}

static const DEVICE_ATTR_RW(force_disable);

static int supplier_notification_setup(struct extcon_usb_shim *shim)
{
	struct device *dev = shim->dev;
	struct device_node *node = dev->of_node;
	struct extcon_dev *supplier;
	int num_extcon;
	int ret;

	num_extcon = of_count_phandle_with_args(node, "extcon", NULL);
	if (num_extcon < 0) {
		dev_err(dev, "Extcon count failed\n");
		return -ENODEV;
	}

	if (num_extcon != 1) {
		dev_err(dev, "Only one extcon allowed, %d provided\n",
			num_extcon);
		return -EINVAL;
	}

	supplier = extcon_get_edev_by_phandle(dev, 0);
	if (IS_ERR(supplier)) {
		return PTR_ERR(supplier);
	}

	shim->supplier_connected = extcon_get_state(supplier, EXTCON_USB);

	shim->supplier_notifier.notifier_call = supplier_change;
	ret = devm_extcon_register_notifier(shim->dev, supplier, EXTCON_USB,
					&shim->supplier_notifier);
	if (ret < 0)
		dev_err(dev,
			"Failed to register notifier for supplier: %d\n", ret);

	return ret;
}

static int setup_own_extcon(struct extcon_usb_shim *shim)
{
	struct device *dev = shim->dev;
	int ret = 0;

	shim->extcon = devm_extcon_dev_allocate(dev, supported_cables);
	if (IS_ERR(shim->extcon)) {
		dev_err(dev, "Failed to allocate extcon device: %d\n", ret);
		return PTR_ERR(shim->extcon);
	}

	ret = devm_extcon_dev_register(dev, shim->extcon);
	if (ret < 0) {
		dev_err(dev, "Failed to register extcon device: %d\n", ret);
		return ret;
	}

	ret = extcon_set_property_capability(shim->extcon, EXTCON_USB,
					EXTCON_PROP_USB_SS);
	if (ret < 0)
		dev_err(dev, "Failed to set property capability: %d\n", ret);

	return ret;
}

static int setup_sysfs(struct extcon_usb_shim *shim)
{
	struct device *dev = shim->dev;
	int ret;

	ret = device_create_file(shim->dev, &dev_attr_force_disable);
	if (ret < 0) {
		dev_err(dev, "Failed to create %s: %d\n",
			dev_attr_force_disable.attr.name, ret);

		/* Nonfatal, but no gating will happen */
		ret = 0;
	}

	return ret;
}

static void teardown_sysfs(struct extcon_usb_shim *shim)
{
	device_remove_file(shim->dev, &dev_attr_force_disable);
}

static void setup_gating_enabled(struct extcon_usb_shim *shim)
{
	struct device *dev = shim->dev;
	struct device_node *node = dev->of_node;

	shim->usb_gate_support =
		of_property_read_bool(node, "usb-gate-supported");

	shim->usb_force_disable =
		shim->usb_gate_support && usb_force_disable_boot;

	dev_info(dev, "USB force-disable:%u changeable:%u (dt-support:%u " \
			"disable-param:0x%u)\n",
		shim->usb_force_disable, shim->usb_gate_support,
		shim->usb_gate_support, usb_force_disable_boot);
}

static int extcon_usb_shim_probe(struct platform_device *pdev)
{
	struct extcon_usb_shim *shim;
	int ret = 0;


	shim = devm_kzalloc(&pdev->dev, sizeof(*shim), GFP_KERNEL);
	if (!shim)
		return -ENOMEM;

	platform_set_drvdata(pdev, shim);
	shim->dev = &pdev->dev;

	mutex_init(&shim->lock);

	ret = setup_own_extcon(shim);
	if (ret < 0) {
		dev_err(shim->dev, "Own extcon setup failed: %d\n", ret);
		return ret;
	}

	ret = supplier_notification_setup(shim);
	if (ret < 0) {
		/* Spoof the connection.
		 * USB PHY will turn on and facilitate debug.
		 */
		dev_err(shim->dev,
			"Supplier notification setup failed: %d\n", ret);
		dev_err(shim->dev, "Extcon will report as connected\n");
		shim->force_report_connected = true;
	}

	ret = setup_sysfs(shim);
	if (ret < 0) {
		dev_err(shim->dev, "Failed to set up sysfs: %d\n", ret);
		return ret;
	}

	setup_gating_enabled(shim);
	update(shim, NULL, false);

	return 0;
}

static int extcon_usb_shim_remove(struct platform_device *pdev)
{
	struct extcon_usb_shim *shim = platform_get_drvdata(pdev);

	teardown_sysfs(shim);
	mutex_destroy(&shim->lock);
	platform_set_drvdata(pdev, NULL);
	return 0;
}

static const struct of_device_id match_table[] = {
	{ .compatible = "google,extcon-usb-shim" },
	{ /* sentinel */ }
};

MODULE_DEVICE_TABLE(of, match_table);

static struct platform_driver extcon_usb_shim = {
	.driver	= {
		.name = "extcon-usb-shim",
		.of_match_table	= of_match_ptr(match_table),
		.pm = NULL,
	},
	.probe		= extcon_usb_shim_probe,
	.remove		= extcon_usb_shim_remove,
};
module_platform_driver(extcon_usb_shim);

MODULE_DESCRIPTION("USB extcon shim");
MODULE_LICENSE("GPL v2");
