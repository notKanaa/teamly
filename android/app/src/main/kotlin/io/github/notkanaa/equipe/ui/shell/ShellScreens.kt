package io.github.notkanaa.equipe.ui.shell

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.layout.wrapContentWidth
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Build
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material.icons.outlined.CheckCircle
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import io.github.notkanaa.equipe.config.ConfigurationIssue
import io.github.notkanaa.equipe.ui.theme.EquipeBrand
import io.github.notkanaa.equipe.ui.theme.extendedColors

/** The app's mark (colours of the app icon): a rounded square with a check mark. Decorative. */
@Composable
fun ShellBrandMark(modifier: Modifier = Modifier, size: Dp = 80.dp) {
    val shape = RoundedCornerShape(size * 0.24f)
    Box(
        modifier = modifier
            .size(size)
            .shadow(elevation = size * 0.1f, shape = shape)
            .background(EquipeBrand.gradient, shape)
            .clearAndSetSemantics {},
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            imageVector = Icons.Outlined.CheckCircle,
            contentDescription = null,
            tint = Color.White,
            modifier = Modifier.size(size * 0.56f),
        )
    }
}

/** Brand mark, app name and a subtitle, centered (top of the authentication screens). */
@Composable
fun ShellBrandHeader(modifier: Modifier = Modifier, title: String = "Équipe", subtitle: String? = null) {
    Column(
        modifier = modifier.fillMaxWidth(),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        ShellBrandMark(size = 76.dp)
        Text(
            text = title,
            style = MaterialTheme.typography.displaySmall,
            color = MaterialTheme.colorScheme.onBackground,
            modifier = Modifier.semantics { heading() },
        )
        if (subtitle != null) {
            Text(
                text = subtitle,
                style = MaterialTheme.typography.bodyLarge,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = TextAlign.Center,
            )
        }
    }
}

/** Shown while the stored session is restored (`AppPhase.Launching`) once the system splash screen is gone. */
@Composable
fun ShellSplash(modifier: Modifier = Modifier) {
    Column(
        modifier = modifier
            .fillMaxSize()
            .background(MaterialTheme.colorScheme.background)
            .testTag(ShellTestTags.SPLASH)
            .clearAndSetSemantics { contentDescription = "Chargement d’Équipe" },
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(24.dp, Alignment.CenterVertically),
    ) {
        ShellBrandMark(size = 96.dp)
        CircularProgressIndicator()
    }
}

/**
 * « Configuration manquante »: the app was built without a usable Supabase project (BuildConfig.SUPABASE_URL /
 * SUPABASE_PUBLISHABLE_KEY), port of the iOS `ShellConfigurationMissingView`.
 */
@Composable
fun ShellConfigurationMissing(issue: ConfigurationIssue, modifier: Modifier = Modifier) {
    Column(
        modifier = modifier
            .fillMaxSize()
            .background(MaterialTheme.colorScheme.background)
            .verticalScroll(rememberScrollState())
            .windowInsetsPadding(WindowInsets.safeDrawing)
            .padding(24.dp)
            .testTag(ShellTestTags.CONFIGURATION_MISSING),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Column(
            modifier = Modifier
                .widthIn(max = 560.dp)
                .fillMaxWidth()
                .wrapContentWidth(),
            verticalArrangement = Arrangement.spacedBy(24.dp),
        ) {
            Column(
                modifier = Modifier.fillMaxWidth(),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Icon(
                    imageVector = Icons.Filled.Build,
                    contentDescription = null,
                    tint = MaterialTheme.extendedColors.warning,
                    modifier = Modifier.size(48.dp),
                )
                Text(
                    text = "Configuration manquante",
                    style = MaterialTheme.typography.headlineSmall,
                    textAlign = TextAlign.Center,
                    modifier = Modifier.semantics { heading() },
                )
                Text(
                    text = "Cette version d’Équipe a été compilée sans l’adresse de votre projet Supabase : elle ne " +
                        "peut pas se connecter.",
                    style = MaterialTheme.typography.bodyLarge,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    textAlign = TextAlign.Center,
                )
            }

            ConfigurationCard(title = "Ce qui manque") {
                for (problem in issue.problems) {
                    Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        Icon(
                            imageVector = Icons.Filled.Warning,
                            contentDescription = null,
                            tint = MaterialTheme.extendedColors.warning,
                        )
                        Text(problem.message, style = MaterialTheme.typography.bodyMedium)
                    }
                }
            }

            ConfigurationCard(title = "Comment corriger") {
                FIX_STEPS.forEachIndexed { index, step ->
                    Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        StepNumber(index + 1)
                        Text(step, style = MaterialTheme.typography.bodyMedium)
                    }
                }
                Text(
                    text = LOCAL_BUILD_NOTE,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    }
}

@Composable
private fun ConfigurationCard(title: String, content: @Composable () -> Unit) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .background(MaterialTheme.extendedColors.card, MaterialTheme.shapes.medium)
            .padding(18.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        Text(
            text = title,
            style = MaterialTheme.typography.titleMedium,
            modifier = Modifier.semantics { heading() },
        )
        content()
    }
}

/** A numbered circle (« 1 », « 2 »…) in front of an instruction. */
@Composable
internal fun StepNumber(number: Int, modifier: Modifier = Modifier) {
    Box(
        modifier = modifier
            .size(24.dp)
            .background(MaterialTheme.colorScheme.primary, CircleShape)
            .clearAndSetSemantics { contentDescription = "Étape $number" },
        contentAlignment = Alignment.Center,
    ) {
        Text(
            text = number.toString(),
            style = MaterialTheme.typography.labelMedium,
            color = MaterialTheme.colorScheme.onPrimary,
        )
    }
}

private val FIX_STEPS = listOf(
    "Sur GitHub, ouvrez votre dépôt › Settings › Secrets and variables › Actions › onglet « Variables ».",
    "Vérifiez SUPABASE_HOST (l’hôte du projet, par exemple « abcdefgh.supabase.co », sans " +
        "« https:// ») et SUPABASE_PUBLISHABLE_KEY (Supabase › Project Settings › API Keys, clé " +
        "« sb_publishable_… »), les mêmes que pour l’app iOS.",
    "Relancez le workflow « Android », puis réinstallez l’APK qu’il produit.",
)

private const val LOCAL_BUILD_NOTE =
    "Sur votre ordinateur : ajoutez equipe.supabaseUrl et equipe.supabaseKey à ~/.gradle/gradle.properties (ou " +
        "définissez les variables d’environnement SUPABASE_URL et SUPABASE_PUBLISHABLE_KEY), puis recompilez l’app."
