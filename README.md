# Spektrafilm LrC-Exp

一个面向 Windows 上 Adobe Lightroom Classic（LrC）的实验性胶片模拟插件项目。目标是让摄影师在 LrC 中完成选片与基础调整，再通过独立浮窗选择胶片和相纸，预览并导出模拟冲印的成片。

**项目状态：设计阶段。** 当前交付为方案说明，尚无可安装的插件版本。

## 计划中的工作流

1. 在 LrC 中按旗标、星级或集合筛选照片，为每张照片调整曝光、白平衡和裁切。
2. 打开「胶片模拟」浮窗，选择胶片和相纸，以当前照片预览组合效果。
3. 在独立导出设置中选择输出目录、格式和尺寸。批量导出时，每张照片沿用自身的 LrC 调整，共用本次选定的胶片和相纸组合。

## 首个原型要验证什么

LrC 插件负责取得选中的照片并生成带调整的图像。外部渲染进程调用 spektrafilm，使用同一组胶片和相纸参数生成预览与成片。首先验证单张照片从预览到导出的流程，比较两者在肤色、阴影与高光上的一致性，并核对传入引擎的色彩空间和传递曲线，再扩展到批量导出。

## 参考项目

- [spektrafilm](https://github.com/andreavolpato/spektrafilm) 提供胶片与相纸模拟引擎。
- [SpektraLab Windows](https://github.com/YZH2006517/SpektraLab-Windows-NANATATA) 是本项目参考的桌面工作流。
- [Adobe Lightroom Classic SDK](https://developer.adobe.com/lightroom-classic/) 提供插件浮窗与导出相关接口。
